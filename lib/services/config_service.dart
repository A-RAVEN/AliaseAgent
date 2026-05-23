import 'dart:convert';
import 'dart:io';

import '../models/app_config.dart';

enum ConfigStatus { ok, notFound, malformed }

class ConfigResult {
  final ConfigStatus status;
  final AppConfig? config;
  final String? error;

  const ConfigResult._({required this.status, this.config, this.error});

  factory ConfigResult.ok(AppConfig config) =>
      ConfigResult._(status: ConfigStatus.ok, config: config);

  factory ConfigResult.notFound() =>
      ConfigResult._(status: ConfigStatus.notFound);

  factory ConfigResult.malformed(String error) =>
      ConfigResult._(status: ConfigStatus.malformed, error: error);
}

class ConfigService {
  static String get _homeDir {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final userProfile = env['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) return userProfile;
      final homeDrive = env['HOMEDRIVE'] ?? '';
      final homePath = env['HOMEPATH'] ?? '';
      return '$homeDrive$homePath';
    }
    return env['HOME'] ?? '';
  }

  static String get homeDir => _homeDir;
  static String get configDir => '$_homeDir${Platform.pathSeparator}.aliasagent';
  static String get configPath => '$configDir${Platform.pathSeparator}config.json';

  static ConfigResult load() {
    final file = File(configPath);
    if (!file.existsSync()) return ConfigResult.notFound();

    try {
      final content = file.readAsStringSync();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return ConfigResult.ok(AppConfig.fromJson(json));
    } on FormatException catch (e) {
      return ConfigResult.malformed('Invalid JSON in $configPath: ${e.message}');
    } on TypeError catch (e) {
      return ConfigResult.malformed('Unexpected data structure in $configPath: ${e.toString()}');
    }
  }

  static void save(AppConfig config) {
    final dir = Directory(configDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File(configPath);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config.toJson()));
  }
}
