export const meta = {
  name: 'grill-me',
  description: 'Two-agent grill-me: Agent 1 relentlessly questions an openspec design, Agent 2 answers with codebase evidence. Covers every branch of the decision tree.',
  phases: [
    { title: 'Gather context', detail: 'Read openspec artifacts and explore relevant code' },
    { title: 'Round 1 questions', detail: 'Agent 1 generates questions across all design branches' },
    { title: 'Round 1 answers', detail: 'Agent 2 investigates and answers each question' },
    { title: 'Round 2 follow-ups', detail: 'Agent 1 reviews answers, generates follow-up questions' },
    { title: 'Round 2 answers', detail: 'Agent 2 answers follow-ups' },
    { title: 'Synthesize', detail: 'Final summary of decisions and open issues' },
  ],
}

// ── Input ──
const changeName = typeof args === 'string' ? args : args?.change
if (!changeName) {
  log('ERROR: No change name provided. Pass the change name as args, e.g. "fix-phase18-state-cleanup".')
  throw new Error('Missing change name')
}

const CHANGE_DIR = `openspec/changes/${changeName}`

// ── Phase 1: Gather context ──
phase('Gather context')

// Read all artifacts in parallel
const [proposal, design, tasks] = await parallel([
  () => agent(
    `Read the file ${CHANGE_DIR}/proposal.md and return its FULL content verbatim. Include every section, every line. Do NOT summarize.`,
    { label: 'read-proposal' }
  ),
  () => agent(
    `Read the file ${CHANGE_DIR}/design.md and return its FULL content verbatim. Include every section, every decision, every risk. Do NOT summarize.`,
    { label: 'read-design' }
  ),
  () => agent(
    `Read the file ${CHANGE_DIR}/tasks.md and return its FULL content verbatim. Include all task groups, all tasks, all checkpoints. Do NOT summarize.`,
    { label: 'read-tasks' }
  ),
])

// Read all spec files
const specList = await agent(
  `List all .md files under ${CHANGE_DIR}/specs/ recursively. Use Glob with pattern "${CHANGE_DIR}/specs/**/*.md". Return the file paths.`,
  { label: 'list-specs' }
)

const specContents = specList
  ? await parallel(
      specList.split('\n').filter(Boolean).map(path => () =>
        agent(
          `Read the file ${path.trim()} and return its FULL content verbatim. Include every requirement, every scenario. Do NOT summarize.`,
          { label: `read-spec:${path.trim().split('/').pop()}` }
        )
      )
    )
  : []

log(`Gathered: proposal, design, tasks, ${specContents.filter(Boolean).length} spec(s)`)

// ── Phase 2: Round 1 — Question generation ──
phase('Round 1 questions')

const round1Questions = await agent(
  `You are Agent 1 (the Griller). Your job is to relentlessly question every aspect of the following openspec design. Walk down EVERY branch of the decision tree.

## Grill-me methodology
- Start from the most architectural/foundational decisions and work outward
- For each decision, ask: what alternatives were considered? why was this chosen? what are the edge cases? what could go wrong?
- Trace dependencies between decisions — if decision A changes, does decision B still hold?
- Challenge assumptions: timing, scope boundaries, risk mitigations, implementation order
- Ask about what's MISSING: unstated preconditions, untested scenarios, unhandled error paths

## Design artifacts

### Proposal
${proposal}

### Design
${design}

### Tasks
${tasks}

### Specs
${specContents.filter(Boolean).join('\n\n---\n\n')}

## Instructions
Generate a comprehensive question tree organized by design decision branch. For each branch, ask:
1. The core question (challenging the decision itself)
2. Edge case questions (boundary conditions)
3. Dependency questions (how this interacts with other decisions)
4. Implementation questions (how this maps to actual code)

Output your questions as a structured JSON object with this schema:
{
  "branches": [
    {
      "branchId": "short-slug-for-this-branch",
      "decision": "Which design decision this questions",
      "questions": [
        {
          "id": "q1",
          "question": "The question text",
          "context": "Why this question matters — which design decision or risk it probes",
          "category": "architecture" | "correctness" | "risk" | "completeness" | "implementation"
        }
      ]
    }
  ]
}

Be relentless. Cover every branch. Every dependency. Every edge case. Generate at least 3 questions per decision branch.`,
  {
    label: 'griller-round-1',
    schema: {
      type: 'object',
      properties: {
        branches: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              branchId: { type: 'string' },
              decision: { type: 'string' },
              questions: {
                type: 'array',
                items: {
                  type: 'object',
                  properties: {
                    id: { type: 'string' },
                    question: { type: 'string' },
                    context: { type: 'string' },
                    category: { type: 'string', enum: ['architecture', 'correctness', 'risk', 'completeness', 'implementation'] },
                  },
                  required: ['id', 'question', 'context', 'category'],
                },
              },
            },
            required: ['branchId', 'decision', 'questions'],
          },
        },
      },
      required: ['branches'],
    },
  }
)

if (!round1Questions) {
  log('ERROR: Round 1 question generation failed.')
  throw new Error('Question generation failed')
}

log(`Generated ${round1Questions.branches.length} branches with ${round1Questions.branches.reduce((sum, b) => sum + b.questions.length, 0)} questions`)

// ── Phase 3: Round 1 — Investigation & Answers ──
phase('Round 1 answers')

const round1Answers = await pipeline(
  round1Questions.branches,
  async (branch) => {
    const answered = await parallel(
      branch.questions.map(q => () =>
        agent(
          `You are Agent 2 (the Investigator). Answer the following question about the openspec change "${changeName}" based STRICTLY on documentation and codebase evidence.

## Question
**Branch**: ${branch.decision}
**Category**: ${q.category}
**Question**: ${q.question}
**Why this matters**: ${q.context}

## Rules for answering
1. **Investigate the codebase first.** Use Grep to find relevant code, Read to examine files. Do NOT answer from memory or assumptions.
2. **Cite sources.** Every claim must reference either: a specific file:line, a spec requirement, a design decision, or a task description.
3. **Answer honestly.** If the documentation/code doesn't address something, say so explicitly — "The design does not cover this scenario."
4. **Provide your recommended answer** based on evidence, with reasoning.

## Context (design artifacts already gathered)
Proposal: ${CHANGE_DIR}/proposal.md
Design: ${CHANGE_DIR}/design.md
Tasks: ${CHANGE_DIR}/tasks.md
Specs: under ${CHANGE_DIR}/specs/
Main code: lib/main.dart (ChatScreenState), lib/ui/chat_area.dart (ChatAreaState), lib/services/session_repository.dart

## Output format
Return a JSON object:
{
  "questionId": "${q.id}",
  "answer": "Your detailed answer with reasoning",
  "evidence": ["file:line — what it shows", "spec requirement X — what it requires"],
  "confidence": "high" | "medium" | "low",
  "uncovered": "What's NOT addressed by the current design/docs (if anything)",
  "recommendation": "Your recommended action (if any)"
}`,
          {
            label: `answer:${q.id}`,
            schema: {
              type: 'object',
              properties: {
                questionId: { type: 'string' },
                answer: { type: 'string' },
                evidence: { type: 'array', items: { type: 'string' } },
                confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
                uncovered: { type: 'string' },
                recommendation: { type: 'string' },
              },
              required: ['questionId', 'answer', 'evidence', 'confidence'],
            },
          }
        )
      )
    )
    return { branchId: branch.branchId, decision: branch.decision, answers: answered.filter(Boolean) }
  }
)

const totalAnswered = round1Answers.reduce((sum, b) => sum + (b?.answers?.length || 0), 0)
log(`Round 1 complete: ${totalAnswered} answers across ${round1Answers.filter(Boolean).length} branches`)

// ── Phase 4: Round 2 — Gap review & follow-ups ──
phase('Round 2 follow-ups')

const gapReview = await agent(
  `You are Agent 1 (the Griller) again. Review ALL the Q&A from Round 1 and identify gaps.

## Round 1 Q&A
${JSON.stringify(round1Answers.filter(Boolean), null, 2)}

## Instructions
For each branch, check:
1. Are there answers with "low" or "medium" confidence? → Generate follow-up questions to resolve uncertainty.
2. Did any answer flag something as "uncovered"? → Generate questions to address the gap.
3. Did any answer reveal a NEW dependency or risk not in the original questions? → Generate follow-up questions.
4. Are there branches of the decision tree we haven't explored? → Generate new branch questions.
5. Are there cross-branch interactions (answer in branch A affects branch B)? → Generate cross-cutting questions.

Output follow-up questions in the same schema as Round 1. If no gaps found, return an empty branches array.`,
  {
    label: 'griller-round-2',
    schema: {
      type: 'object',
      properties: {
        branches: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              branchId: { type: 'string' },
              decision: { type: 'string' },
              questions: {
                type: 'array',
                items: {
                  type: 'object',
                  properties: {
                    id: { type: 'string' },
                    question: { type: 'string' },
                    context: { type: 'string' },
                    category: { type: 'string', enum: ['architecture', 'correctness', 'risk', 'completeness', 'implementation'] },
                  },
                  required: ['id', 'question', 'context', 'category'],
                },
              },
            },
            required: ['branchId', 'decision', 'questions'],
          },
        },
      },
      required: ['branches'],
    },
  }
)

const hasFollowUps = gapReview && gapReview.branches.length > 0
log(hasFollowUps
  ? `Gaps found: ${gapReview.branches.length} branches with ${gapReview.branches.reduce((s, b) => s + b.questions.length, 0)} follow-up questions`
  : 'No gaps found — design is fully covered.')

// ── Phase 5: Round 2 — Investigation & Answers (only if gaps) ──
let round2Answers = []
if (hasFollowUps) {
  phase('Round 2 answers')

  round2Answers = await pipeline(
    gapReview.branches,
    async (branch) => {
      const answered = await parallel(
        branch.questions.map(q => () =>
          agent(
            `You are Agent 2 (the Investigator). Answer this FOLLOW-UP question based on codebase evidence.

## Question
**Branch**: ${branch.decision}
**Category**: ${q.category}
**Question**: ${q.question}
**Why this matters**: ${q.context}

## Rules
1. Investigate the codebase. Use Grep and Read. Do not answer from memory.
2. Cite sources: file:line, spec requirements, design decisions.
3. Answer honestly — flag what's not covered.
4. Provide your recommended answer.

## Output format
{
  "questionId": "${q.id}",
  "answer": "Your detailed answer with reasoning",
  "evidence": ["file:line — what it shows"],
  "confidence": "high" | "medium" | "low",
  "uncovered": "What's NOT addressed",
  "recommendation": "Your recommended action"
}`,
            {
              label: `answer:${q.id}`,
              schema: {
                type: 'object',
                properties: {
                  questionId: { type: 'string' },
                  answer: { type: 'string' },
                  evidence: { type: 'array', items: { type: 'string' } },
                  confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
                  uncovered: { type: 'string' },
                  recommendation: { type: 'string' },
                },
                required: ['questionId', 'answer', 'evidence', 'confidence'],
              },
            }
          )
        )
      )
      return { branchId: branch.branchId, decision: branch.decision, answers: answered.filter(Boolean) }
    }
  )

  log(`Round 2 complete: ${round2Answers.reduce((s, b) => s + (b?.answers?.length || 0), 0)} follow-up answers`)
}

// ── Phase 6: Synthesis ──
phase('Synthesize')

const synthesis = await agent(
  `You are the Synthesizer. Produce the final grill-me report for openspec change "${changeName}".

## All Q&A

### Round 1
${JSON.stringify(round1Answers.filter(Boolean), null, 2)}

### Round 2 (follow-ups)
${JSON.stringify(round2Answers.filter(Boolean), null, 2)}

## Instructions
Produce a structured final report:

1. **Decision Tree Summary** — For each design decision, state: what was decided, whether the evidence supports it, confidence level, and any unresolved concerns.

2. **Issues Found** — List every concrete issue discovered during grilling:
   - Design gaps (scenarios not covered)
   - Missing dependencies (decision A depends on unstated assumption B)
   - Risk under-mitigation (risk acknowledged but mitigation insufficient)
   - Implementation concerns (task doesn't match design, or missing task)

3. **Recommendations** — For each issue, recommend a concrete change to the openspec artifacts (proposal/design/specs/tasks).

4. **Confidence Matrix** — Per branch: confidence (high/medium/low) and why.

Output as a detailed markdown report. Be thorough — this is the final deliverable.`,

  { label: 'synthesize' }
)

log('Grill-me complete.')
return {
  changeName,
  round1Branches: round1Questions.branches.length,
  round1Questions: round1Questions.branches.reduce((s, b) => s + b.questions.length, 0),
  round1Answered: totalAnswered,
  hasFollowUps,
  round2Answered: round2Answers.reduce((s, b) => s + (b?.answers?.length || 0), 0),
  synthesis,
}
