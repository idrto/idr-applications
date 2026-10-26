import 'dart:convert';
import 'dart:io';

import 'package:idr_client/idr_client.dart';
import 'package:idr_service_http/idr_service_http.dart';

import 'models.dart';

/// Source helper for Hugging Face OpenAI-compatible HTTP via Target gateway.
///
/// Target injects `Authorization` from HF_TOKEN; Source never sees the token.
class IdrHuggingFaceClient {
  IdrHuggingFaceClient(
    this.session, {
    this.serviceName = 'huggingface',
    this.hostHeader = 'router.huggingface.co',
  }) : _http = IdrServiceHttpClient(
          session,
          serviceName: serviceName,
          hostHeader: hostHeader,
        );

  final IdrSession session;
  final String serviceName;
  final String hostHeader;
  final IdrServiceHttpClient _http;

  Future<List<HfModelInfo>> listModels({int maxRead = 1024 * 1024}) async {
    final map = await _http.httpJson(
      method: 'GET',
      path: '/v1/models',
      maxRead: maxRead,
      bodyLooksComplete: (body) {
        final t = body.trimLeft();
        return t.startsWith('{') && t.contains('"data"');
      },
    );
    final raw = map['data'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => HfModelInfo.fromJson(Map<String, dynamic>.from(e)))
        .where((m) => m.id.isNotEmpty)
        .toList();
  }

  Future<HfChatResponse> chat(
    HfChatRequest request, {
    int maxRead = 1024 * 1024,
  }) async {
    final map = await _http.httpJson(
      method: 'POST',
      path: '/v1/chat/completions',
      body: jsonEncode(request.toJson()),
      maxRead: maxRead,
      bodyLooksComplete: (body) {
        final t = body.trimLeft();
        return t.startsWith('{') &&
            (t.contains('"choices"') || t.contains('"error"'));
      },
    );
    if (map['error'] != null) {
      throw StateError('Hugging Face error: ${map['error']}');
    }
    return HfChatResponse.fromJson(map);
  }

  Future<String> ask({
    required String model,
    required String prompt,
    List<ChatTurn> history = const [],
  }) async {
    final messages = [
      ...history,
      ChatTurn(role: 'user', content: prompt),
    ];
    final resp = await chat(HfChatRequest(model: model, messages: messages));
    return resp.content;
  }

  /// Text-to-image via fal-compatible path through the generic gateway.
  Future<HfImageResult> generateImage({
    required String model,
    required String prompt,
    String providerPath = '/fal-ai/fal-ai/flux/schnell',
    int maxRead = 12 * 1024 * 1024,
  }) async {
    final map = await _http.httpJson(
      method: 'POST',
      path: providerPath,
      body: jsonEncode({'prompt': prompt}),
      maxRead: maxRead,
      timeout: const Duration(seconds: 180),
      bodyLooksComplete: (body) {
        final t = body.trimLeft();
        return t.startsWith('{') &&
            (t.contains('"images"') ||
                t.contains('"b64_json"') ||
                t.contains('"error"'));
      },
    );
    if (map['error'] != null && map['images'] == null) {
      throw StateError('Hugging Face image error: ${map['error']}');
    }
    final images = map['images'];
    if (images is List && images.isNotEmpty && images.first is Map) {
      final first = Map<String, dynamic>.from(images.first as Map);
      final url = first['url'] as String?;
      if (url != null && url.isNotEmpty) {
        final uri = Uri.parse(url);
        final client = HttpClient();
        try {
          final req = await client.getUrl(uri);
          final resp = await req.close();
          final bytes = await resp.fold<List<int>>(
            <int>[],
            (a, b) => a..addAll(b),
          );
          return HfImageResult(
            bytes: bytes,
            mime: (first['content_type'] as String?) ?? 'image/jpeg',
          );
        } finally {
          client.close(force: true);
        }
      }
    }
    final data = map['data'];
    if (data is List && data.isNotEmpty && data.first is Map) {
      final first = Map<String, dynamic>.from(data.first as Map);
      final b64 = first['b64_json'] as String?;
      if (b64 != null && b64.isNotEmpty) {
        return HfImageResult(
          bytes: base64Decode(b64),
          mime: (first['mime'] as String?) ?? 'image/jpeg',
        );
      }
    }
    throw StateError('No image in Hugging Face response: $map');
  }
}
