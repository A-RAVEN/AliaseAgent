// WebSocket 通道上的 JSON-RPC 2.0 分发（change `web-ui-core-shim` 任务 2.2）。
//
// 只做协议层：解析 → 校验 → 找方法 → 调 handler → 组装响应。传输（WebSocket）
// 与业务方法在 `headless_core.dart`。错误码一律用 JSON-RPC 2.0 规范值，
// 不发明新的错误码：
//   -32700 Parse error
//   -32600 Invalid Request
//   -32601 Method not found
//   -32602 Invalid params
//   -32603 Internal error
//
// 约定：带 `id` 的消息回响应；没有 `id` 的消息是 notification，执行后**不回任何
// 东西**（JSON-RPC 2.0 §4.1）。非法 JSON / 非法请求即使没有 id 也回 `id:null` 的
// 错误响应（§5），否则客户端会静默卡住。
import 'dart:async';
import 'dart:convert';

import '../services/logging.dart';

/// JSON-RPC 2.0 规范错误码。
abstract final class JsonRpcErrorCode {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
}

/// 方法实现主动抛出的、带规范错误码的失败。
class JsonRpcException implements Exception {
  final int code;
  final String message;
  final Object? data;

  const JsonRpcException(this.code, this.message, {this.data});

  @override
  String toString() => 'JsonRpcException($code): $message';
}

/// 一个方法的实现：参数对象已校验为 JSON 对象。
typedef JsonRpcMethod = FutureOr<Object?> Function(Map<String, dynamic> params);

/// 协议分发器：按方法名注册 handler，`handleRawText` 吃原始文本、吐响应文本。
class JsonRpcDispatcher {
  final Map<String, JsonRpcMethod> _methods = <String, JsonRpcMethod>{};

  /// 已注册的方法名（诊断 / 测试用）。
  List<String> get methodNames => List<String>.unmodifiable(_methods.keys);

  void register(String method, JsonRpcMethod handler) {
    _methods[method] = handler;
  }

  /// 处理一条 WebSocket 文本消息。返回要回写的文本；notification 返回 null。
  ///
  /// 批量请求（JSON 数组）按规范逐条处理；全是 notification 时同样返回 null。
  Future<String?> handleRawText(String raw) async {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      return jsonEncode(_errorResponse(
          null, JsonRpcErrorCode.parseError, 'Parse error: ${e.message}'));
    }

    if (decoded is List) {
      if (decoded.isEmpty) {
        return jsonEncode(_errorResponse(null, JsonRpcErrorCode.invalidRequest,
            'Invalid Request: 批量请求不能为空数组'));
      }
      final responses = <Object?>[];
      for (final item in decoded) {
        final response = await _handleOne(item);
        if (response != null) responses.add(response);
      }
      return responses.isEmpty ? null : jsonEncode(responses);
    }

    final response = await _handleOne(decoded);
    return response == null ? null : jsonEncode(response);
  }

  /// 处理一条已解码的消息。notification 返回 null。
  Future<Map<String, dynamic>?> _handleOne(Object? decoded) async {
    if (decoded is! Map) {
      return _errorResponse(null, JsonRpcErrorCode.invalidRequest,
          'Invalid Request: 消息必须是 JSON 对象');
    }
    final hasId = decoded.containsKey('id');
    final rawId = decoded['id'];
    if (hasId && rawId is! String && rawId is! num && rawId != null) {
      return _errorResponse(null, JsonRpcErrorCode.invalidRequest,
          'Invalid Request: id 只能是字符串、数字或 null');
    }
    final id = hasId ? rawId : null;

    final jsonrpc = decoded['jsonrpc'];
    final method = decoded['method'];
    if (jsonrpc != '2.0' || method is! String || method.isEmpty) {
      return _errorResponse(id, JsonRpcErrorCode.invalidRequest,
          'Invalid Request: 需要 jsonrpc="2.0" 与字符串 method');
    }

    final rawParams = decoded['params'];
    Map<String, dynamic> params;
    if (rawParams == null) {
      params = <String, dynamic>{};
    } else if (rawParams is Map) {
      params = Map<String, dynamic>.from(rawParams);
    } else {
      if (!hasId) return null;
      return _errorResponse(id, JsonRpcErrorCode.invalidParams,
          'Invalid params: params 必须是对象（本核心不支持位置参数）');
    }

    final handler = _methods[method];
    if (handler == null) {
      // notification 的错误不回复（JSON-RPC 2.0 §4.1），带 id 的才回。
      if (!hasId) return null;
      return _errorResponse(id, JsonRpcErrorCode.methodNotFound,
          'Method not found: $method');
    }

    try {
      final result = await handler(params);
      if (!hasId) return null;
      return <String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'result': result ?? const <String, dynamic>{},
      };
    } on JsonRpcException catch (e) {
      if (!hasId) return null;
      return _errorResponse(id, e.code, e.message, data: e.data);
    } catch (e, st) {
      debugPrint('[AliasAgent] JSON-RPC 方法 "$method" 未预期异常：$e\n$st');
      if (!hasId) return null;
      return _errorResponse(id, JsonRpcErrorCode.internalError,
          'Internal error: $e');
    }
  }

  Map<String, dynamic> _errorResponse(
    Object? id,
    int code,
    String message, {
    Object? data,
  }) =>
      <String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, dynamic>{
          'code': code,
          'message': message,
          'data': ?data,
        },
      };
}
