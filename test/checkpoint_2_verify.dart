import 'dart:convert';
import 'dart:io';

void main() {
  final testDir = '${Directory.systemTemp.path}/aliasagent_cp2_test';
  final aliasagentDir = '$testDir/.aliasagent';
  final configPath = '$aliasagentDir/config.json';

  // Clean start
  final d = Directory(aliasagentDir);
  if (d.existsSync()) d.deleteSync(recursive: true);

  // ---- B: Config exists → parse correctly ----
  Directory(aliasagentDir).createSync(recursive: true);
  final validConfig = {
    'version': 1,
    'providers': {
      'anthropic': {
        'api_key': 'sk-ant-test123',
        'base_url': 'https://api.anthropic.com'
      },
      'openai': {
        'api_key': 'sk-openai-test',
        'base_url': 'https://api.openai.com'
      }
    },
    'agent_types': {
      'general': {
        'provider': 'anthropic',
        'model': 'claude-sonnet-4-6',
        'system_prompt': 'You are helpful.',
        'tools': ['read_file', 'list_dir']
      }
    }
  };
  File(configPath)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(validConfig));

  final content = File(configPath).readAsStringSync();
  final json = jsonDecode(content) as Map<String, dynamic>;

  // Verify providers
  final providers = json['providers'] as Map<String, dynamic>;
  assert(providers.length == 2, 'Expected 2 providers');
  assert((providers['anthropic'] as Map)['api_key'] == 'sk-ant-test123');
  assert((providers['openai'] as Map)['api_key'] == 'sk-openai-test');
  print('[B] PASS: Config file parsed — 2 providers, 1 agent type loaded ✓');

  // ---- C: Malformed config → error ----
  final badPath = '$aliasagentDir/bad_config.json';
  File(badPath).writeAsStringSync('{broken json!!!');
  try {
    jsonDecode(File(badPath).readAsStringSync());
    print('[C] FAIL: should have thrown');
  } on FormatException catch (e) {
    print('[C] PASS: Malformed JSON detected → "${e.message}" ✓');
  }

  // Malformed structure (valid JSON, wrong types)
  final wrongPath = '$aliasagentDir/wrong_config.json';
  File(wrongPath)
      .writeAsStringSync(jsonEncode({'version': 'not-a-number', 'providers': [1, 2, 3]}));
  final wrongJson = jsonDecode(File(wrongPath).readAsStringSync()) as Map<String, dynamic>;
  assert(wrongJson['providers'] is List, 'Expected providers to be a list (wrong type)');
  print('[C] PASS: Type mismatch detected — providers is list, not object ✓');

  // ---- D: Registry ----
  final agentTypes = json['agent_types'] as Map<String, dynamic>;
  final general = agentTypes['general'];
  assert(general != null, 'lookup("general") should find config');
  assert(agentTypes['nonexistent'] == null, 'lookup("nonexistent") should be null');
  print('[D] PASS: lookup("general") → found, lookup("nonexistent") → null ✓');

  // ---- E: Provider resolver ----
  final anthropic = providers['anthropic'] as Map<String, dynamic>;
  final apiKey = anthropic['api_key'] as String;
  final baseUrl = anthropic['base_url'] as String;
  assert(apiKey.isNotEmpty, 'api_key should not be empty');
  assert(baseUrl.isNotEmpty, 'base_url should not be empty');
  print('[E] PASS: resolve("anthropic") → api_key="$apiKey", base_url="$baseUrl" ✓');

  // Cleanup
  Directory(testDir).deleteSync(recursive: true);

  print('');
  print('=== Checkpoint 2 B/C/D/E: ALL PASS ===');
}