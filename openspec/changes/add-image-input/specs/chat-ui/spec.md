## ADDED Requirements

### Requirement: User message images in the bubble

A user message that carries attachments SHALL render the attached images inside its bubble, above the text, constrained by an explicit `BoxConstraints` of `maxWidth: 600` and `maxHeight: 400`（出处：`lib/ui/message_bubble.dart` 既有的 `constraints: const BoxConstraints(maxWidth: 600)`，以及 `lib/ui/tool_call_card.dart` 既有的 `constraints: const BoxConstraints(maxHeight: 400)`）—— 与 `read_image` 卡片共用同一组界，一张 4000×3000 的截图不会把对话推走。

For each attached image:

- the file exists and decodes → SHALL show the image;
- the file is missing or unreadable → SHALL show a visible line `[图片已丢失：<path>]` in place of the image;
- the image was not sent because the model does not declare image input → SHALL show the image plus the line `模型未声明图片输入，本次没有发送图片`.

The bubble MUST NOT throw or render a blank space when a file cannot be read.

#### Scenario: Bubble shows the attached image
- **WHEN** a user message with one PNG attachment is displayed
- **THEN** an `Image.file` for that path is present in the bubble, and the enclosing constrained box has `maxWidth <= 600` and `maxHeight <= 400`

#### Scenario: Missing file shows the visible fallback
- **WHEN** a user message's attachment path no longer exists on disk
- **THEN** the bubble contains the text `[图片已丢失：<path>]` and does not throw

#### Scenario: Text-only model shows the notice
- **WHEN** a user message with an image is displayed while `input_modalities` excludes `image`
- **THEN** the bubble contains the text `模型未声明图片输入，本次没有发送图片`
