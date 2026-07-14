## ADDED Requirements

### Requirement: HTTP request construction
The C++ Sidecar SHALL construct HTTP POST requests with correct headers and JSON body.

#### Scenario: Request includes required headers
- **WHEN** send_message constructs an HTTP request
- **THEN** the request includes headers: x-api-key, anthropic-version, content-type: application/json

#### Scenario: Request body includes all fields
- **WHEN** send_message constructs an HTTP request
- **THEN** the JSON body includes model, messages, system, tools, and stream:true fields

### Requirement: HTTP timeout handling
The C++ Sidecar SHALL enforce a configurable timeout and report timeout errors.

#### Scenario: Request times out
- **WHEN** the API does not respond within the timeout period (default 120s)
- **THEN** the connection is closed
- **AND** on_done is called with a timeout error

### Requirement: Non-200 response handling
The C++ Sidecar SHALL handle HTTP error responses and report via on_done.

#### Scenario: HTTP 401 Unauthorized
- **WHEN** the API returns HTTP 401
- **THEN** on_done is called with non-zero code and "Authentication failed" error

#### Scenario: HTTP 500 Server Error
- **WHEN** the API returns HTTP 500
- **THEN** on_done is called with non-zero code and the response body (truncated to 2048 chars)
