export const meta = {
  name: 'adversarial-review-zhipuai',
  description: 'Multi-angle adversarial review of fix-zhipuai-web-search-api proposal',
  phases: [
    { title: 'Fact-Check', detail: 'Verify every claim in design/specs against official API docs' },
    { title: 'Consistency', detail: 'Check internal consistency across all 4 artifacts' },
    { title: 'Gap Analysis', detail: 'Find missing requirements, edge cases, test coverage gaps' },
    { title: 'Synthesize', detail: 'Merge findings, dedup, rank by severity' }
  ],
}

const CHANGE = 'fix-zhipuai-web-search-api'
const BASE = `openspec/changes/${CHANGE}`

// Read all artifacts
const proposalText = await agent(`Read ${BASE}/proposal.md and return its full content`, {label: 'read-proposal'})
const designText = await agent(`Read ${BASE}/design.md and return its full content`, {label: 'read-design'})
const tasksText = await agent(`Read ${BASE}/tasks.md and return its full content`, {label: 'read-tasks'})
const searchSpecText = await agent(`Read ${BASE}/specs/search-provider/spec.md and return its full content`, {label: 'read-search-spec'})
const zhipuaiSpecText = await agent(`Read ${BASE}/specs/zhipuai-web-search-api/spec.md and return its full content`, {label: 'read-zhipuai-spec'})
const currentImpl = await agent(`Read sidecar/src/zhipuai_search.cpp and sidecar/src/zhipuai_search.h and return their full content`, {label: 'read-current-impl'})
const currentTests = await agent(`Read sidecar/test/search_provider_test.cpp and extract only the ZhipuAI-related test cases (search for "[zhipuai]" tag) and return their full content`, {label: 'read-current-tests'})
const searchProviderH = await agent(`Read sidecar/src/search_provider.h and return its full content`, {label: 'read-provider-h'})

// ============================================================================
// Phase 1: Fact-Check — every claim vs official docs
// ============================================================================
phase('Fact-Check')

const officialApiDoc = `
OFFICIAL Z.AI WEB SEARCH API (from docs.z.ai/api-reference/tools/web-search):

ENDPOINT: POST https://api.z.ai/api/paas/v4/web_search
(Chinese platform: https://open.bigmodel.cn/api/paas/v4/web_search)
NOTE: The path is /api/paas/v4/web_search — there is NO "tools/" segment in the path.

REQUEST BODY (application/json):
- search_engine: enum<string>, default "search-prime", REQUIRED
  Available values: "search-prime" (Z.AI Premium Version Search Engine)
  Note: "search_pro_jina" is mentioned in count/docs for domain/recency filter support
- search_query: string, REQUIRED — the content to be searched
- count: integer, range 1-50, default 10 — number of results to return
- search_domain_filter: string, optional — whitelist domain (e.g. www.example.com)
- search_recency_filter: enum, optional — oneDay|oneWeek|oneMonth|oneYear|noLimit (default: noLimit)
- request_id: string, optional, 6-64 chars
- user_id: string, optional, 6-128 chars

NOTE: There is NO "content_size" field in the official API.

RESPONSE 200:
{
  "id": "<string>",           // Task ID
  "created": 123,             // Unix timestamp in seconds
  "search_result": [
    {
      "title": "<string>",    // Title
      "content": "<string>",  // Content summary
      "link": "<string>",     // Result URL
      "media": "<string>",    // Website name
      "icon": "<string>",     // Website icon
      "refer": "<string>",    // Index number
      "publish_date": "<string>" // Publication date
    }
  ]
}

ERROR RESPONSE:
{
  "code": 123,
  "message": "<string>"
}
NOTE: Error format is {code, message}, NOT {error: {message: "..."}}.

AUTHORIZATION: Bearer <token> header (same as Chat Completions API)
`

const factCheckFindings = await agent(
  `You are an adversarial fact-checker. Your job is to find EVERY factual discrepancy between the proposal artifacts and the official API documentation.

OFFICIAL API DOCUMENTATION:
${officialApiDoc}

PROPOSAL ARTIFACTS:
=== proposal.md ===
${proposalText}

=== design.md ===
${designText}

=== tasks.md ===
${tasksText}

=== specs/search-provider/spec.md ===
${searchSpecText}

=== specs/zhipuai-web-search-api/spec.md ===
${zhipuaiSpecText}

For EACH claim in the proposal artifacts, verify it against the official docs. Report EVERY discrepancy you find.

Format each finding as:
- SEVERITY: [CRITICAL|HIGH|MEDIUM|LOW]
- FILE: which artifact file
- CLAIM: what the artifact claims
- REALITY: what the official docs say
- IMPACT: what breaks if we implement as-written

Be thorough. Check:
1. Endpoint URL path
2. Request field names and types
3. Request field values (especially enums like search_engine)
4. Response format
5. Error response format
6. Authentication method
7. Any invented/non-existent fields
8. Any missing required fields`,
  {label: 'fact-check', schema: {
    type: 'object',
    properties: {
      findings: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            severity: { type: 'string', enum: ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'] },
            file: { type: 'string' },
            claim: { type: 'string' },
            reality: { type: 'string' },
            impact: { type: 'string' }
          },
          required: ['severity', 'file', 'claim', 'reality', 'impact']
        }
      }
    },
    required: ['findings']
  }}
)

// ============================================================================
// Phase 2: Internal Consistency Check
// ============================================================================
phase('Consistency')

const consistencyFindings = await agent(
  `You are a consistency auditor. Check ALL 4 proposal artifacts for internal contradictions.

Artifacts:
=== proposal.md ===
${proposalText}

=== design.md ===
${designText}

=== tasks.md ===
${tasksText}

=== specs/search-provider/spec.md ===
${searchSpecText}

=== specs/zhipuai-web-search-api/spec.md ===
${zhipuaiSpecText}

=== Current implementation (zhipuai_search.cpp/h) ===
${currentImpl}

Find contradictions like:
- Proposal says one thing, design says another
- Design says X, tasks say Y
- Spec requires A, tasks don't cover A
- Proposal mentions files to change, but tasks don't include those files
- Design decision contradicts a spec requirement
- Tasks reference fields/values that don't exist in design
- Spec scenario not covered by any task

Report every contradiction found.`,
  {label: 'consistency-check', schema: {
    type: 'object',
    properties: {
      findings: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            severity: { type: 'string', enum: ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'] },
            artifacts: { type: 'string' },
            contradiction: { type: 'string' },
            resolution: { type: 'string' }
          },
          required: ['severity', 'artifacts', 'contradiction', 'resolution']
        }
      }
    },
    required: ['findings']
  }}
)

// ============================================================================
// Phase 3: Gap Analysis
// ============================================================================
phase('Gap Analysis')

const gapFindings = await agent(
  `You are a test coverage and requirements gap auditor. Find what's MISSING from the proposal.

Artifacts:
=== proposal.md ===
${proposalText}
=== design.md ===
${designText}
=== tasks.md ===
${tasksText}
=== specs (both) ===
${searchSpecText}
${zhipuaiSpecText}

Current implementation (for reference on what exists):
${currentImpl}
${currentTests}

Provider interface:
${searchProviderH}

Official API docs:
${officialApiDoc}

Find gaps:
1. API features the official docs support that the proposal doesn't address
2. Error scenarios not covered by specs or tests
3. Edge cases not mentioned (empty query, special characters, very long query, etc.)
4. Missing test cases (compare tasks.md test list against spec scenarios)
5. Missing cleanup tasks (e.g., removing old Chat Completions code, updating comments)
6. Integration points not addressed (Dart side, config.json format, etc.)
7. Response fields the official API returns that aren't mapped
8. Anything the current implementation does that the tasks don't mention changing

Be exhaustive. Every gap is a potential bug.`,
  {label: 'gap-analysis', schema: {
    type: 'object',
    properties: {
      findings: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            severity: { type: 'string', enum: ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW'] },
            category: { type: 'string' },
            what_is_missing: { type: 'string' },
            consequence: { type: 'string' },
            suggested_fix: { type: 'string' }
          },
          required: ['severity', 'category', 'what_is_missing', 'consequence', 'suggested_fix']
        }
      }
    },
    required: ['findings']
  }}
)

// ============================================================================
// Phase 4: Synthesize
// ============================================================================
phase('Synthesize')

const allFindings = [
  ...(factCheckFindings?.findings || []).map(f => ({...f, source: 'fact-check'})),
  ...(consistencyFindings?.findings || []).map(f => ({...f, source: 'consistency'})),
  ...(gapFindings?.findings || []).map(f => ({...f, source: 'gap-analysis'}))
]

log(`Total raw findings: ${allFindings.length}`)

const synthesized = await agent(
  `Synthesize these adversarial review findings into a ranked, deduplicated report.

Raw findings from 3 review passes:
${JSON.stringify(allFindings, null, 2)}

Instructions:
1. Merge duplicate/similar findings
2. Rank by severity: CRITICAL > HIGH > MEDIUM > LOW
3. Within same severity, group by topic (endpoint, request format, response parsing, testing, etc.)
4. For each finding, provide a concrete fix recommendation
5. Add a summary section at the top with counts by severity
6. Flag any finding that would cause a RUNTIME FAILURE (API returns error) vs DOCUMENTATION error

Output a structured verdict.`,
  {label: 'synthesize', schema: {
    type: 'object',
    properties: {
      summary: {
        type: 'object',
        properties: {
          critical_count: { type: 'integer' },
          high_count: { type: 'integer' },
          medium_count: { type: 'integer' },
          low_count: { type: 'integer' },
          overall_verdict: { type: 'string' }
        },
        required: ['critical_count', 'high_count', 'medium_count', 'low_count', 'overall_verdict']
      },
      findings: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            rank: { type: 'integer' },
            severity: { type: 'string' },
            topic: { type: 'string' },
            description: { type: 'string' },
            would_cause_runtime_failure: { type: 'boolean' },
            fix: { type: 'string' },
            affected_artifacts: { type: 'array', items: { type: 'string' } }
          },
          required: ['rank', 'severity', 'topic', 'description', 'would_cause_runtime_failure', 'fix', 'affected_artifacts']
        }
      }
    },
    required: ['summary', 'findings']
  }}
)

return {
  factCheck: factCheckFindings,
  consistency: consistencyFindings,
  gapAnalysis: gapFindings,
  synthesized
}
