import 'package:idr_client/idr_client.dart';
import 'package:idr_huggingface/idr_huggingface.dart';
import 'package:idr_ollama/idr_ollama.dart';
import 'package:idr_service_http/idr_service_http.dart' show ChatTurn;

import '../catalog/service_selection.dart';
import '../errors.dart';

/// Chat / model listing against an active Target service.
class ChatGateway {
  Future<String> chat({
    required IdrSession session,
    required ServiceSelection service,
    required String model,
    required String prompt,
    List<ChatTurn> history = const [],
    Future<void> Function(String delta)? onDelta,
  }) async {
    final kind = await _effectiveKind(session, service);
    if (kind == 'ollama') {
      final client = _ollama(session, service);
      return client.ask(
        model: model,
        prompt: prompt,
        history: history,
        onDelta: onDelta,
      );
    }
    if (kind == 'huggingface' || kind == 'openai' || kind == 'generic') {
      final client = _openai(session, service);
      // OpenAI-compatible upstreams (LM Studio, HF, …) return one full reply;
      // surface it via onDelta so CLI / UIs that only print deltas still show text.
      final reply = await client.ask(
        model: model,
        prompt: prompt,
        history: history,
      );
      if (onDelta != null && reply.isNotEmpty) {
        await onDelta(reply);
      }
      return reply;
    }
    throw IdrSourceException(
      code: 'SERVICE_UNSUPPORTED',
      message: 'Chat is not supported for service kind "${service.kind}".',
    );
  }

  Future<List<String>> listModels({
    required IdrSession session,
    required ServiceSelection service,
  }) async {
    if (service.isPostgres) return const [];

    final kind = await _effectiveKind(session, service);
    if (kind == 'ollama') {
      final listed = await _ollama(session, service).listModels();
      return listed.map((m) => m.name).where((n) => n.isNotEmpty).toList()
        ..sort();
    }

    try {
      final listed = await _openai(session, service).listModels();
      final ids = listed.map((m) => m.id).where((n) => n.isNotEmpty).toList();
      if (service.isHuggingFace &&
          !ids.any((id) => id.contains('FLUX.1-schnell'))) {
        ids.add('black-forest-labs/FLUX.1-schnell');
      }
      ids.sort();
      return ids;
    } catch (_) {
      if (service.isHuggingFace) {
        return const ['black-forest-labs/FLUX.1-schnell'];
      }
      rethrow;
    }
  }

  IdrOllamaClient _ollama(IdrSession session, ServiceSelection service) =>
      IdrOllamaClient(
        session,
        serviceName: service.name,
        hostHeader: service.hostHeader ?? '127.0.0.1:11434',
      );

  IdrHuggingFaceClient _openai(IdrSession session, ServiceSelection service) =>
      IdrHuggingFaceClient(
        session,
        serviceName: service.name,
        hostHeader: service.hostHeader ?? service.name,
      );

  Future<String> _effectiveKind(
    IdrSession session,
    ServiceSelection service,
  ) async {
    if (!service.isGeneric) return service.kind;
    try {
      final listed = await _ollama(session, service).listModels();
      if (listed.isNotEmpty) return 'ollama';
    } catch (_) {}
    try {
      final listed = await _openai(session, service).listModels();
      if (listed.isNotEmpty) return 'openai';
    } catch (_) {}
    return 'openai';
  }
}
