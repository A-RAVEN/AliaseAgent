## ADDED Requirements

### Requirement: Code block rendering
The system SHALL render fenced code blocks in assistant messages with monospace font and a visually distinct background.

#### Scenario: Fenced code block with language
- **WHEN** an assistant MessageBubble contains a fenced code block with language identifier (e.g., ```dart)
- **THEN** the code block is rendered with a monospace font family
- **AND** the code block has a distinct background color from the message text

#### Scenario: Fenced code block without language
- **WHEN** an assistant MessageBubble contains a fenced code block without language identifier (```)
- **THEN** the code block is rendered with monospace font
- **AND** the code block has a distinct background color from the message text

#### Scenario: Inline code within normal text
- **WHEN** an assistant MessageBubble contains `inline code` surrounded by backticks
- **THEN** the inline code is rendered with monospace font, visually distinct from surrounding text

### Requirement: Markdown formatting
The system SHALL render bold, italic, links, lists, and other Markdown formatting in assistant messages.

#### Scenario: Bold text
- **WHEN** an assistant message contains **bold** Markdown
- **THEN** the bold text is rendered with FontWeight.bold or equivalent

#### Scenario: Italic text
- **WHEN** an assistant message contains *italic* Markdown
- **THEN** the italic text is rendered with italic font style

#### Scenario: Links
- **WHEN** an assistant message contains a Markdown link [text](url)
- **THEN** the link text is rendered as tappable/colored text

#### Scenario: Unordered list
- **WHEN** an assistant message contains `- item1\n- item2`
- **THEN** the items are rendered as a bulleted list
