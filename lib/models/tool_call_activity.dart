enum ToolCallStatus { executing, done, error }

class ToolCallActivity {
  final String id;
  final String toolName;
  final Map<String, dynamic> input;
  final ToolCallStatus status;
  final String? result;
  final String? resultPreview;

  const ToolCallActivity({
    required this.id,
    required this.toolName,
    required this.input,
    this.status = ToolCallStatus.executing,
    this.result,
    this.resultPreview,
  });

  ToolCallActivity copyWith({
    String? id,
    String? toolName,
    Map<String, dynamic>? input,
    ToolCallStatus? status,
    String? result,
    String? resultPreview,
  }) {
    return ToolCallActivity(
      id: id ?? this.id,
      toolName: toolName ?? this.toolName,
      input: input ?? this.input,
      status: status ?? this.status,
      result: result ?? this.result,
      resultPreview: resultPreview ?? this.resultPreview,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'toolName': toolName,
        'input': input,
        'status': status.name,
        'result': result,
        'resultPreview': resultPreview,
      };

  factory ToolCallActivity.fromJson(Map<String, dynamic> json) {
    return ToolCallActivity(
      id: json['id'] as String? ?? '',
      toolName: json['toolName'] as String? ?? 'unknown',
      input: (json['input'] as Map<String, dynamic>?) ?? {},
      status: ToolCallStatus.values.byName(
        (json['status'] as String?) ?? 'executing',
      ),
      result: json['result'] as String?,
      resultPreview: json['resultPreview'] as String?,
    );
  }
}