## ADDED Requirements

### Requirement: HTTP request construction
The C++ Sidecar SHALL construct HTTP POST requests with correct headers and JSON body.

#### Scenario: Request includes required headers
- **WHEN** build_request constructs an HTTP request
- **THEN** the request includes headers: x-api-key, anthropic-version: 2023-06-01, content-type: application/json

#### Scenario: Request body includes all fields
- **WHEN** build_request constructs an HTTP request with all fields present
- **THEN** the JSON body includes model, messages, system, tools, stream:true, and max_tokens:4096 fields

#### Scenario: Optional fields omitted when empty
- **WHEN** system is empty/null or tools is empty/null
- **THEN** the corresponding field is excluded from the JSON body

#### Scenario: Default base_url
- **WHEN** base_url is empty or null
- **THEN** the URL defaults to `https://api.anthropic.com/v1/messages`

### Requirement: API key validation
The C++ Sidecar SHALL handle empty or null API key at the FFI boundary.

#### Scenario: Empty API key
- **WHEN** send_message is called with an empty or null api_key
- **THEN** on_done(0, "", "") is called immediately with code 0
- **AND** no HTTP request is made (returns 1 without reaching ModelGateway)

### Requirement: Input JSON validation
The C++ Sidecar SHALL validate and report errors for malformed input JSON.

#### Scenario: Invalid messages_json
- **WHEN** send_message receives messages_json that is not valid JSON
- **THEN** on_done(-1, "Invalid messages JSON", "") is called before any HTTP request

#### Scenario: Invalid tools_json
- **WHEN** send_message receives tools_json that is not valid JSON
- **THEN** on_done(-1, "Invalid tools JSON", "") is called before any HTTP request

### Requirement: Request ID generation
The C++ Sidecar SHALL assign a monotonically increasing request_id to each request.

#### Scenario: Request IDs are unique and increasing
- **WHEN** multiple send_message calls are made
- **THEN** each returns a distinct integer greater than the previous

### Requirement: HTTP 401 handling
The C++ Sidecar SHALL specifically handle HTTP 401 responses.

#### Scenario: HTTP 401 Unauthorized
- **WHEN** the API returns HTTP 401
- **THEN** on_done is called with code -1 and error "Authentication failed — invalid API key"

### Requirement: Non-200 HTTP response handling
The C++ Sidecar SHALL handle HTTP error responses and report via on_done with a generic error message.

NOTE: The implementation returns a fixed string `"API returned HTTP <code>"` and does NOT read the response body. This is a simplification; the error response body (typically JSON from the API) is not captured or forwarded.

#### Scenario: HTTP 500 Server Error
- **WHEN** the API returns HTTP 500
- **THEN** on_done is called with code -1 and error "API returned HTTP 500"

#### Scenario: Other HTTP errors (403, 429, 502, 503)
- **WHEN** the API returns any HTTP status >= 400 (except 401)
- **THEN** on_done is called with code -1 and error "API returned HTTP <code>"
