import 'dart:convert';

import 'package:idr_client/idr_client.dart';
import 'package:idr_service_http/idr_service_http.dart';

import 'models.dart';

/// Opens Target named service (default `ollama`) and speaks Ollama HTTP API.
class IdrOllamaClient {
  IdrOllamaClient(
    this.session, {
    this.serviceName = 'ollama',
    this.hostHeader = '127.0.0.1:11434',
  }) : _http = IdrServiceHttpClient(
          session,
          serviceName: serviceName,
          hostHeader: hostHeader,
        );

  final IdrSession session;
  final String serviceName;
  final String hostHeader;
  final IdrServiceHttpClient _http;

  Future<List<OllamaModelInfo>> listModels({int maxRead = 1024 * 1024}) async {
    final map = await _http.httpJson(
      method: 'GET',
      path: '/api/tags',
      maxRead: maxRead,
      bodyLooksComplete: (body) {
        final t = body.trimLeft();
        return t.startsWith('{') && t.contains('"models"');
      },
    );
    final raw = map['models'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => OllamaModelInfo.fromJson(Map<String, dynamic>.from(e)))
        .where((m) => m.name.isNotEmpty)
        .toList();
  }

  Future<OllamaChatResponse> chat(
    OllamaChatRequest request, {
    int maxRead = 1024 * 1024,
  }) async {
    final map = await _http.httpJson(
      method: 'POST',
      path: '/api/chat',
      body: jsonEncode(request.toJson()),
      maxRead: maxRead,
      bodyLooksComplete: (body) {
        final t = body.trimLeft();
        return t.startsWith('{') && t.contains('"message"');
      },
    );
    return OllamaChatResponse.fromJson(map);
  }

  /// Streams assistant token deltas from Ollama (`stream: true`).
  Stream<String> chatDeltas(OllamaChatRequest request) async* {
    final streamed = OllamaChatRequest(
      model: request.model,
      messages: request.messages,
      stream: true,
    );
    await for (final map in _http.httpNdjson(
      method: 'POST',
      path: '/api/chat',
      body: jsonEncode(streamed.toJson()),
    )) {
      final msg = map['message'];
      if (msg is Map) {
        final content = msg['content'];
        if (content is String && content.isNotEmpty) yield content;
      }
    }
  }

  Future<String> ask({
    required String model,
    required String prompt,
    List<ChatTurn> history = const [],
    Future<void> Function(String delta)? onDelta,
  }) async {
    final messages = [
      ...history,
      ChatTurn(role: 'user', content: prompt),
    ];
    final request = OllamaChatRequest(model: model, messages: messages);
    if (onDelta == null) {
      final resp = await chat(request);
      return resp.message.content;
    }
    final buf = StringBuffer();
    await for (final delta in chatDeltas(request)) {
      buf.write(delta);
      await onDelta(delta);
    }
    return buf.toString();
  }
}
