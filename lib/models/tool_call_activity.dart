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

class ToolCallActivity {
  final String id;
  final String toolName;
  final Map<String, dynamic> input;
  final ToolCallStatus status;
  final String? result;
  final String? resultPreview;
  final List<ResultSection>? resultSections;

  const ToolCallActivity({
    required this.id,
    required this.toolName,
    required this.input,
    this.status = ToolCallStatus.executing,
    this.result,
    this.resultPreview,
    this.resultSections,
  });

  ToolCallActivity copyWith({
    String? id,
    String? toolName,
    Map<String, dynamic>? input,
    ToolCallStatus? status,
    String? result,
    String? resultPreview,
    List<ResultSection>? resultSections,
  }) {
    return ToolCallActivity(
      id: id ?? this.id,
      toolName: toolName ?? this.toolName,
      input: input ?? this.input,
      status: status ?? this.status,
      result: result ?? this.result,
      resultPreview: resultPreview ?? this.resultPreview,
      resultSections: resultSections ?? this.resultSections,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'toolName': toolName,
        'input': input,
        'status': status.name,
        'result': result,
        'resultPreview': resultPreview,
        if (resultSections != null)
          'resultSections': resultSections!.map((s) => s.toJson()).toList(),
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
    );
  }
}