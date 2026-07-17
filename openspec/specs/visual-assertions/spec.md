## ADDED Requirements

### Requirement: Screenshot capture of AliasAgent window
The system SHALL capture a screenshot of the AliasAgent application window using PowerShell `CopyFromScreen`.

#### Scenario: App window is visible and PowerShell is available
- **WHEN** `alias_agent.exe` is running with a visible window
- **AND** PowerShell `CopyFromScreen` captures the primary screen to a PNG file
- **THEN** a PNG file is saved at the specified path
- **AND** the file size is non-zero

#### Scenario: Screenshot capture fails
- **WHEN** PowerShell is not available or `CopyFromScreen` fails
- **THEN** the step exits with code 1
- **AND** an error message indicates the capture failure

### Requirement: Visual regression comparison
The system SHALL support comparing a newly captured screenshot against a known-good reference screenshot using MCP `ui_diff_check`.

#### Scenario: UI unchanged from reference
- **WHEN** actual screenshot is compared against reference
- **AND** no significant visual difference exists
- **THEN** MCP tool reports minimal or no differences
- **AND** the verification is considered passed

#### Scenario: UI has changed
- **WHEN** actual screenshot differs from reference
- **THEN** MCP tool reports the differences
- **AND** the differences are reviewed to determine if intentional (UI feature change) or unintentional (regression)

#### Scenario: Reference image missing
- **WHEN** the reference screenshot does not exist at the expected path
- **THEN** the comparison is skipped with a warning
- **AND** the actual screenshot is saved for future use as a reference

### Requirement: Empty state visual verification
The system SHALL verify the empty state UI shows a sidebar with "New Chat" session and a main area with "No messages yet" placeholder text.

#### Scenario: App launched with no active conversation
- **WHEN** the app has sessions but no current conversation content
- **THEN** MCP `extract_text_from_screenshot` detects "New Chat" in the sidebar area
- **AND** detects "No messages yet" in the main content area

### Requirement: Auto-title visual verification
The system SHALL verify that the sidebar session title updates from the default "New Chat" after the first user message.

#### Scenario: First message sent
- **WHEN** the first user message text is 30 characters or fewer
- **THEN** MCP `extract_text_from_screenshot` detects the full message text as the session title in the sidebar

#### Scenario: Long first message truncated
- **WHEN** the first user message exceeds 30 characters
- **THEN** MCP `extract_text_from_screenshot` detects the first 30 characters followed by "..." as the session title

### Requirement: Tool card visual verification
The system SHALL verify that tool call cards appear in the message list when the model invokes a tool, visually differentiated from regular message bubbles.

#### Scenario: Tool call in conversation
- **WHEN** the model invokes a tool (e.g., `list_dir` or `read_file`)
- **THEN** MCP `analyze_image` detects a card in the message area that is visually distinct from adjacent message bubbles
- **AND** the card displays the tool name and input parameters

### Requirement: Error state visual verification
The system SHALL verify that error messages appear as distinct error bubbles in the message list when an API call or tool execution fails.

#### Scenario: API error occurs
- **WHEN** the model API returns an error (e.g., timeout or authentication failure)
- **THEN** MCP `analyze_image` detects an error bubble in the message area
- **AND** the bubble contains the error message text
