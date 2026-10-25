## ADDED Requirements

### Requirement: read_image via FFI

The dynamic library SHALL export `read_image(const char* request_json)` where `request_json` is `{"path":"…"}`. It SHALL return a NUL-terminated UTF-8 JSON string owned by the library (same lifetime contract as `read_file` and `grep_file`): `{"ok":true,"content":"…","image":{…}}` on success, `{"ok":false,"error":"…"}` on failure. Dart SHALL resolve the symbol at startup and a missing symbol SHALL surface as a startup error naming the function, not a crash.

#### Scenario: Symbol resolves and returns JSON
- **WHEN** Dart calls the exported `read_image` with a valid image path inside the workspace
- **THEN** the returned string parses as JSON with `ok == true`, and `image.media_type` / `image.width` / `image.height` / `image.bytes` are all present

#### Scenario: Failure shape matches the other tools
- **WHEN** the exported `read_image` is called with a non-existent path
- **THEN** the returned JSON has `ok == false` and an `error` string, and no `image` object

### Requirement: read_clipboard_image via FFI

The dynamic library SHALL export `read_clipboard_image(const char* request_json)` where `request_json` is `{"dest_dir":"<absolute directory>"}`. It SHALL read the current clipboard image, write it as a PNG file into that directory, and return `{"ok":true,"path":"<absolute path>","media_type":"image/png","width":W,"height":H,"bytes":N}`. When the clipboard holds no image it SHALL return `{"ok":false,"error":"clipboard has no image"}`. When the directory cannot be created or the file cannot be written it SHALL return `{"ok":false,"error":"<reason>"}`.

It MUST NOT open any window. The clipboard read SHALL be reachable through an injectable function so the test binary never calls Win32 `OpenClipboard`; the real Win32 path is covered only by the live test.

#### Scenario: Clipboard holds an image
- **WHEN** the injected clipboard source yields bitmap bytes and `read_clipboard_image` is called with an existing directory
- **THEN** a new `.png` file exists in that directory and the JSON reports its absolute path, `image/png`, and non-zero width/height/bytes

#### Scenario: Clipboard holds text only
- **WHEN** the injected clipboard source yields nothing
- **THEN** the call returns `ok:false` with `error` equal to `clipboard has no image`, and no file is written

#### Scenario: Destination directory is created
- **WHEN** `dest_dir` points at a directory that does not exist yet
- **THEN** the directory is created recursively and the PNG is written inside it
