enum ToolCallStatus { executing, done, error }

class ResultItem {
  final String? title;
  final String? url;
  final String? content;

  const ResultItem({this.title, this.url, this.content});

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'content': content,
      };

  factory ResultItem.fromJson(Map<String, dynamic> json) {
    return ResultItem(
      title: json['title'] as String?,
      url: json['url'] as String?,
      content: json['content'] as String?,
    );
  }
}

class ResultSection {
  final String label;
  final String? error;
  final List<ResultItem> items;

  const ResultSection({
    required this.label,
    this.error,
    this.items = const [],
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'error': error,
        'items': items.map((i) => i.toJson()).toList(),
      };

  factory ResultSection.fromJson(Map<String, dynamic> json) {
    return ResultSection(
      label: (json['label'] as String?) ?? '',
      error: json['error'] as String?,
      items: (json['items'] as List<dynamic>?)
              ?.map((e) => ResultItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// 一处实际被替换的片段：行号从 1 数起，oldText/newText 是磁盘上真实进出的文本。
class EditHunk {
  final int startLine;
  final String oldText;
  final String newText;

  const EditHunk({
    required this.startLine,
    required this.oldText,
    required this.newText,
  });

  Map<String, dynamic> toJson() => {
        'start_line': startLine,
        'old_text': oldText,
        'new_text': newText,
      };

  factory EditHunk.fromJson(Map<String, dynamic> json) {
    return EditHunk(
      startLine: (json['start_line'] as num?)?.toInt() ?? 0,
      oldText: (json['old_text'] as String?) ?? '',
      newText: (json['new_text'] as String?) ?? '',
    );
  }
}

class ToolCallActivity {
  final String id;
  final String toolName;
  final Map<String, dynamic> input;
  final ToolCallStatus status;
  final String? result;
  final String? resultPreview;
  final List<ResultSection>? resultSections;

  /// edit_file 实际改动的每一处（行号 + 磁盘上真实进出的文本）；非 edit_file 为 null。
  final List<EditHunk>? hunks;

  /// sidecar 因体积过大省略了 hunks 时带的原因（如 "too large"），否则为 null。
  final String? hunksOmitted;

  /// 这次工具调用带回来的图片路径（`read_image` 才有），否则为 null。
  ///
  /// **只存路径**：库里不存字节、不存宽高/媒体类型/字节数（用户要求"历史先只存
  /// 路径"，见 `Message.attachments`）。卡片要显示的那些数字从 `result` 里的文字
  /// 信封解析，解析不到再读一次文件头 —— 存一份元数据只会在源文件被换掉之后撒谎。
  final String? imagePath;

  const ToolCallActivity({
    required this.id,
    required this.toolName,
    required this.input,
    this.status = ToolCallStatus.executing,
    this.result,
    this.resultPreview,
    this.resultSections,
    this.hunks,
    this.hunksOmitted,
    this.imagePath,
  });

  ToolCallActivity copyWith({
    String? id,
    String? toolName,
    Map<String, dynamic>? input,
    ToolCallStatus? status,
    String? result,
    String? resultPreview,
    List<ResultSection>? resultSections,
    List<EditHunk>? hunks,
    String? hunksOmitted,
    String? imagePath,
  }) {
    return ToolCallActivity(
      id: id ?? this.id,
      toolName: toolName ?? this.toolName,
      input: input ?? this.input,
      status: status ?? this.status,
      result: result ?? this.result,
      resultPreview: resultPreview ?? this.resultPreview,
      resultSections: resultSections ?? this.resultSections,
      hunks: hunks ?? this.hunks,
      hunksOmitted: hunksOmitted ?? this.hunksOmitted,
      imagePath: imagePath ?? this.imagePath,
    );
  }

  /// 把 `image` 这个字段写成 `{"path": "…"}` —— **只有一个键**。
  ///
  /// 这个形状与请求拼装里 `_toolImagePath` 读的完全一致；多一个键就是违背
  /// "历史只存路径"。
  Map<String, dynamic>? get imageJson =>
      imagePath == null ? null : {'path': imagePath};

  Map<String, dynamic> toJson() => {
        'id': id,
        'toolName': toolName,
        'input': input,
        'status': status.name,
        'result': result,
        'resultPreview': resultPreview,
        if (resultSections != null)
          'resultSections': resultSections!.map((s) => s.toJson()).toList(),
        if (hunks != null && hunks!.isNotEmpty)
          'hunks': hunks!.map((h) => h.toJson()).toList(),
        if (hunksOmitted != null) 'hunksOmitted': hunksOmitted,
        if (imagePath != null) 'image': imageJson,
      };

  factory ToolCallActivity.fromJson(Map<String, dynamic> json) {
    return ToolCallActivity(
      id: json['id'] as String? ?? '',
      toolName: (json['toolName'] ?? json['name']) as String? ?? 'unknown',
      input: (json['input'] as Map<String, dynamic>?) ?? {},
      status: ToolCallStatus.values.byName(
        (json['status'] as String?) ?? 'executing',
      ),
      result: json['result'] as String?,
      resultPreview: json['resultPreview'] as String?,
      resultSections: (json['resultSections'] as List<dynamic>?)
          ?.map((e) => ResultSection.fromJson(e as Map<String, dynamic>))
          .toList(),
      hunks: (json['hunks'] as List<dynamic>?)
          ?.map((e) => EditHunk.fromJson(e as Map<String, dynamic>))
          .toList(),
      hunksOmitted: json['hunksOmitted'] as String?,
      // 只读 `path`：老数据里就算混进了别的键，也不会被带进内存模型。
      imagePath: (json['image'] is Map)
          ? ((json['image'] as Map)['path'] as String?)
          : null,
    );
  }
}