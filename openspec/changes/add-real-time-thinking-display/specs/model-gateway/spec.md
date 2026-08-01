## ADDED Requirements

### Requirement: Curl execution on dedicated thread
The C++ Sidecar SHALL execute `curl_easy_perform` on a dedicated `std::thread`, with the FFI calling thread joining the curl thread before returning. This keeps the synchronous send_message contract while allowing callback dispatch to occur in real-time.

#### Scenario: Request executes on curl thread
- **WHEN** `send_message` is invoked
- **THEN** curl runs on a dedicated thread and the FFI call returns only after curl completes

#### Scenario: Callbacks fire during stream
- **WHEN** SSE events arrive during the curl stream
- **THEN** callbacks (on_chunk, on_thinking) are invoked from the curl thread in real-time, before curl completes

### Requirement: Tool use remains block-complete delivery
Tool use JSON SHALL continue to be delivered only at `content_block_stop` after all `input_json_delta` fragments are accumulated and parsed. No incremental tool_use events SHALL be emitted.

#### Scenario: Tool use delivered at block stop
- **WHEN** a tool_use block streams input_json_delta fragments
- **THEN** on_tool_call fires once at content_block_stop with the complete JSON
