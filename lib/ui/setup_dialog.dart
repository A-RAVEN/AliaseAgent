import 'package:flutter/material.dart';

import '../models/agent_type_config.dart';
import '../models/app_config.dart';
import '../models/provider_config.dart';
import '../services/config_service.dart';

class SetupDialog extends StatefulWidget {
  final VoidCallback onComplete;

  const SetupDialog({super.key, required this.onComplete});

  @override
  State<SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<SetupDialog> {
  final _keyController = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  void _submit() {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'Please enter an API key');
      return;
    }

    setState(() => _saving = true);

    final config = _buildDefaultConfig(key);
    ConfigService.save(config);

    widget.onComplete();
  }

  AppConfig _buildDefaultConfig(String apiKey) {
    return AppConfig(
      version: 1,
      providers: {
        'anthropic': ProviderConfig(
          apiKey: apiKey,
          baseUrl: 'https://api.anthropic.com',
        ),
      },
      agentTypes: {
        'general': AgentTypeConfig(
          name: 'general',
          provider: 'anthropic',
          model: 'claude-sonnet-4-6',
          systemPrompt: 'You are a helpful assistant.',
          tools: ['read_file', 'list_dir'],
        ),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Welcome to AliasAgent'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'To get started, enter your Anthropic API key.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _keyController,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: 'sk-ant-...',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            enabled: !_saving,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Start'),
        ),
      ],
    );
  }
}
