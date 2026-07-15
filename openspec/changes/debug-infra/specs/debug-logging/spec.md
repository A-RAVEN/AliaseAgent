# Debug Logging — Spec

## ADDED Requirements

### Requirement: LOG_TRACE log level
The Logger SHALL support a TRACE log level below INFO, controlled by the `ALIASAGENT_LOG_LEVEL` environment variable read at `Logger::init()` time.

#### Scenario: TRACE enabled via environment variable
- **WHEN** the process starts with `ALIASAGENT_LOG_LEVEL=trace`
- **AND** `Logger::init()` is called
- **THEN** `LOG_TRACE` messages are written to the log file
- **AND** `LOG_INFO` messages continue to be written

#### Scenario: Default level is INFO
- **WHEN** `ALIASAGENT_LOG_LEVEL` is not set
- **AND** `Logger::init()` is called
- **THEN** `LOG_TRACE` messages are suppressed (not written to the log file)

#### Scenario: Invalid level value
- **WHEN** `ALIASAGENT_LOG_LEVEL` is set to an unrecognized value (e.g., "debug")
- **THEN** Logger defaults to INFO level

### Requirement: Lazy log message evaluation
The LOG_TRACE macro SHALL check the current log level BEFORE evaluating the message argument, so that disabled TRACE messages incur no string allocation overhead.

#### Scenario: TRACE disabled — no allocation in hot path
- **WHEN** log level is INFO (TRACE disabled)
- **AND** code calls `LOG_TRACE("expensive " + expensive_string_computation())`
- **THEN** `expensive_string_computation()` is NOT called
- **AND** no string concatenation or allocation occurs

#### Scenario: TRACE enabled — message evaluated normally
- **WHEN** log level is TRACE
- **AND** code calls `LOG_TRACE("message: " + value)`
- **THEN** the message is evaluated and written to the log file

### Requirement: Log rotation on init
At `Logger::init()` time, if `sidecar.log` exceeds 10MB, the system SHALL rotate log files, keeping at most 3 historical log files.

#### Scenario: Log file exceeds 10MB
- **WHEN** `Logger::init()` is called and `sidecar.log` is > 10MB
- **THEN** the file is renamed to `sidecar.1.log`
- **AND** existing `sidecar.1.log` is renamed to `sidecar.2.log`
- **AND** `sidecar.3.log` is deleted if it exists

#### Scenario: Log file under 10MB
- **WHEN** `Logger::init()` is called and `sidecar.log` is < 10MB
- **THEN** no rotation occurs; new log entries are appended

### Requirement: API error response body logging
When the model API returns HTTP status ≥ 400, the sidecar SHALL log the first 2048 bytes of the raw response body.

#### Scenario: HTTP 400 error with JSON body
- **WHEN** `curl_easy_perform` completes with HTTP 400
- **AND** the response body is `{"error":{"message":"Invalid model"}}`
- **THEN** `LOG_ERR("API error body: {"error":{"message":"Invalid model"}}")` is written

#### Scenario: Response body truncated at 2048 bytes
- **WHEN** the response body exceeds 2048 bytes
- **THEN** only the first 2048 bytes are logged, with "..." appended

#### Scenario: Raw body buffer bounded at 64KB
- **WHEN** the streaming response body exceeds 64KB during SSE parsing
- **THEN** the `raw_body` buffer stops accumulating (but SSE parsing continues normally)

### Requirement: Raw body capture in write callback
The HTTP write callback SHALL capture all received data into a bounded raw buffer BEFORE SSE line parsing.

#### Scenario: Non-SSE error response captured
- **WHEN** the API returns a plain JSON error (not SSE-formatted)
- **THEN** the raw JSON is captured in the `raw_body` buffer and logged on HTTP ≥ 400

#### Scenario: SSE streaming response captured
- **WHEN** the API returns normal SSE streaming data
- **AND** HTTP status is 200
- **THEN** the `raw_body` buffer accumulates but is NOT logged (no error condition)
