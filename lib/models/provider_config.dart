class ProviderConfig {
  final String apiKey;
  final String baseUrl;

  const ProviderConfig({
    required this.apiKey,
    required this.baseUrl,
  });

  factory ProviderConfig.fromJson(Map<String, dynamic> json) {
    return ProviderConfig(
      apiKey: json['api_key'] as String,
      baseUrl: json['base_url'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'api_key': apiKey,
        'base_url': baseUrl,
      };
}
