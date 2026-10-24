## ADDED Requirements

### Requirement: read_image card shows the image

A `read_image` tool activity SHALL carry a structured image field alongside its text result whose only key is `path` — `{"path":"<absolute path>"}`. This field SHALL be persisted inside `tool_calls` JSON next to `result` / `hunks` and SHALL survive reload (same persistence contract as the edit hunks). Width / height / media type / byte count MUST NOT be persisted — the database stores paths only (see `session-persistence`), so the card reads them from the already-persisted `result` envelope (which contains `image/png image, 800x600 px, 12345 bytes`) and falls back to reading the file header when the envelope cannot be parsed.

The card SHALL render:

- title: `read_image` plus the path only (no metadata in the title);
- collapsed body: a thumbnail of that image plus one metadata line `image/png · 800×600 · 12345 字节`;
- expanded body: the text envelope in full, then the same image at full size.

Both the thumbnail and the full-size image SHALL be constrained by an explicit `BoxConstraints`: width ≤ 600 (source: the existing `constraints: const BoxConstraints(maxWidth: 600)` in `lib/ui/message_bubble.dart`) and height ≤ 400 (source: the existing `constraints: const BoxConstraints(maxHeight: 400)` in `lib/ui/tool_call_card.dart`; `lib/ui/thinking_card.dart` already pairs `maxWidth: 600` with `maxHeight: 400`).

When the file is missing the card SHALL show the text `[图片已丢失：<path>]` instead of the image and MUST NOT throw.

#### Scenario: Collapsed card already shows the image
- **WHEN** a finished `read_image` card is displayed without expanding it
- **THEN** an `Image.file` for that path is present in the card's collapsed subtree, together with the metadata line

#### Scenario: Expanded card shows the envelope
- **WHEN** the card is expanded
- **THEN** the `<path>` / `<type>image</type>` envelope text is visible

#### Scenario: Image survives reload
- **WHEN** a session containing a `read_image` round is reloaded from the database
- **THEN** the card again renders the image thumbnail, driven by the persisted `path` field in `tool_calls`, and the metadata line still shows the dimensions parsed from the persisted `result`

#### Scenario: Persisted activity holds no metadata
- **WHEN** the `tool_calls` JSON of a finished `read_image` round is read back from the database
- **THEN** its `image` object has exactly one key, `path`, and contains none of `width` / `height` / `media_type` / `bytes`

#### Scenario: Image is bounded
- **WHEN** a card renders a 4000×3000 screenshot
- **THEN** the rendered image widget's constraints have `maxWidth <= 600` and `maxHeight <= 400`

#### Scenario: Missing file degrades visibly
- **WHEN** the image file has been deleted before the card renders
- **THEN** the card shows `[图片已丢失：<path>]` and does not throw

### Requirement: Image results do not inflate the request or the estimate twice

The persisted `image` field on a tool activity SHALL NOT appear in the assistant `tool_use` blocks sent to the provider (only its `type` / `id` / `name` / `input` do), and the context estimator SHALL account for the image as exactly 1024 tokens — not as the base64 payload it will become at send time.

#### Scenario: Request body has no tool activity image field
- **WHEN** a request is built for the turn following a `read_image` call
- **THEN** the assistant `tool_use.input` for that call contains only the parameters the model supplied, with no `image` / `width` / `bytes` keys added by the activity

#### Scenario: Estimator counts the image once
- **WHEN** a session holds one `read_image` round with one image
- **THEN** the estimated token total exceeds the same session without that image by exactly 1024
