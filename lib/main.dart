import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

import 'models/app_config.dart';
import 'services/agent_type_registry.dart';
import 'services/config_service.dart';
import 'services/provider_resolver.dart';
import 'ui/setup_dialog.dart';

// C function signature: const char* ping(void)
typedef PingNative = Pointer<Utf8> Function();
typedef PingDart = Pointer<Utf8> Function();

final registry = AgentTypeRegistry();
ProviderResolver? resolver;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AliasAgent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppConfig? _config;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  void _loadConfig() {
    final result = ConfigService.load();
    switch (result.status) {
      case ConfigStatus.ok:
        setState(() {
          _config = result.config;
          _populateRegistry(result.config!);
        });
      case ConfigStatus.notFound:
        WidgetsBinding.instance.addPostFrameCallback((_) => _showSetup());
      case ConfigStatus.malformed:
        setState(() => _error = result.error);
    }
  }

  void _populateRegistry(AppConfig config) {
    for (final type in config.agentTypes.values) {
      registry.register(type);
    }
    resolver = ProviderResolver(config);
  }

  void _showSetup() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => SetupDialog(onComplete: () {
        Navigator.of(context).pop();
        _loadConfig();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
          title: const Text('Configuration Error'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ),
      );
    }

    if (_config == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return MyHomePage(
      title: 'AliasAgent',
      config: _config!,
    );
  }
}

class MyHomePage extends StatefulWidget {
  final String title;
  final AppConfig config;

  const MyHomePage({super.key, required this.title, required this.config});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String _pingResult = 'not run';
  String _ffiStatus = 'not loaded';

  @override
  void initState() {
    super.initState();
    _testFfiPing();
  }

  void _testFfiPing() {
    try {
      final lib = _openSidecar();
      final pingFn = lib.lookupFunction<PingNative, PingDart>('ping');
      final result = pingFn();
      final text = result.toDartString();
      setState(() {
        _ffiStatus = 'loaded OK';
        _pingResult = text;
      });
    } catch (e) {
      setState(() {
        _ffiStatus = 'failed';
        _pingResult = e.toString();
      });
    }
  }

  DynamicLibrary _openSidecar() {
    if (Platform.isWindows) return DynamicLibrary.open('sidecar.dll');
    if (Platform.isMacOS) return DynamicLibrary.open('libsidecar.dylib');
    if (Platform.isLinux) return DynamicLibrary.open('libsidecar.so');
    throw UnsupportedError('Unsupported platform');
  }

  @override
  Widget build(BuildContext context) {
    final passed = _pingResult == 'pong';

    // Checkpoint 2 verification info
    final providerNames = widget.config.providers.keys.join(', ');
    final agentTypeNames = registry.listNames().join(', ');
    final generalConfig = registry.lookup('general');
    final generalProvider = generalConfig?.provider ?? 'N/A';
    final generalModel = generalConfig?.model ?? 'N/A';
    final lookupNonexistent = registry.lookup('nonexistent');
    final resolved = resolver?.resolve('anthropic');
    final hasAnthropicKey =
        resolved != null && resolved.apiKey.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // --- Checkpoint 1: FFI Ping ---
              Icon(
                passed ? Icons.check_circle : Icons.error,
                size: 48,
                color: passed ? Colors.green : Colors.red,
              ),
              const SizedBox(height: 8),
              Text(
                'Checkpoint 1: FFI Ping',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              _row('FFI Load', _ffiStatus),
              _row('ping() →', _pingResult),
              _row('Expected', 'pong'),
              _row('Result', passed ? 'PASS' : 'FAIL',
                  color: passed ? Colors.green : Colors.red),

              const Divider(height: 40),

              // --- Checkpoint 2: Config ---
              Text(
                'Checkpoint 2: Config Round-trip',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              _row('Providers', providerNames),
              _row('Agent Types', agentTypeNames),
              _row('General Provider', generalProvider),
              _row('General Model', generalModel),
              _row('Registry lookup("general")',
                  generalConfig != null ? 'found' : 'null'),
              _row('Registry lookup("nonexistent")',
                  lookupNonexistent != null ? 'found' : 'null'),
              _row('Provider resolve("anthropic")',
                  hasAnthropicKey ? 'has key' : 'missing'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 220,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          Flexible(
            child: Text(value,
                style: TextStyle(color: color, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
