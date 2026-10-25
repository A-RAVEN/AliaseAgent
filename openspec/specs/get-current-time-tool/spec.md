# Get Current Time Tool — Spec

## Purpose

约束"查当前时间"工具：参数校验、时区正确、结果格式稳定。

## Requirements

### Requirement: AI can query current time
The system SHALL provide a `get_current_time` tool that returns the current date, time, and timezone in ISO 8601 format.

#### Scenario: AI queries current time successfully
- **WHEN** the AI calls `get_current_time` with no arguments
- **THEN** the system SHALL return `{"ok":true,"datetime":"<ISO 8601>","date":"<YYYY-MM-DD>","time":"<HH:MM:SS>","timezone":"<offset>"}`

#### Scenario: Tool is always available
- **WHEN** the tool definitions are built
- **THEN** `get_current_time` SHALL be included regardless of configuration
