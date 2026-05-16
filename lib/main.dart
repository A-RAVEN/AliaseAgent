import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

// C function signature: const char* ping(void)
typedef PingNative = Pointer<Utf8> Function();
typedef PingDart = Pointer<Utf8> Function();

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
      home: const MyHomePage(title: 'AliasAgent'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

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
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              passed ? Icons.check_circle : Icons.error,
              size: 64,
              color: passed ? Colors.green : Colors.red,
            ),
            const SizedBox(height: 16),
            Text(
              'Checkpoint 1: FFI Ping',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 24),
            _row('FFI Load', _ffiStatus),
            const SizedBox(height: 8),
            _row('ping() →', _pingResult),
            const SizedBox(height: 8),
            _row('Expected', 'pong'),
            const SizedBox(height: 8),
            _row('Result', passed ? 'PASS' : 'FAIL',
                color: passed ? Colors.green : Colors.red),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Text(value, style: TextStyle(color: color)),
      ],
    );
  }
}