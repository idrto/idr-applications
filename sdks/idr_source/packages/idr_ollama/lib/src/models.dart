import 'package:idr_service_http/idr_service_http.dart';

/// Request/response models for Ollama HTTP API over an IDR stream.
class OllamaChatRequest {
  const OllamaChatRequest({
    required this.model,
    required this.messages,
    this.stream = false,
  });

  final String model;
  final List<ChatTurn> messages;
  final bool stream;

  Map<String, dynamic> toJson() => {
        'model': model,
        'messages': messages.map((m) => m.toJson()).toList(),
        'stream': stream,
      };
}

class OllamaChatResponse {
  const OllamaChatResponse({
    required this.model,
    required this.message,
    this.done = true,
  });

  final String model;
  final ChatTurn message;
  final bool done;

  factory OllamaChatResponse.fromJson(Map<String, dynamic> j) {
    final msg = j['message'];
    return OllamaChatResponse(
      model: j['model'] as String? ?? '',
      message: msg is Map<String, dynamic>
          ? ChatTurn.fromJson(msg)
          : const ChatTurn(role: 'assistant', content: ''),
      done: j['done'] as bool? ?? true,
    );
  }
}

/// One entry from Ollama `GET /api/tags`.
class OllamaModelInfo {
  const OllamaModelInfo({required this.name, this.size, this.modifiedAt});

  final String name;
  final int? size;
  final String? modifiedAt;

  factory OllamaModelInfo.fromJson(Map<String, dynamic> j) => OllamaModelInfo(
        name: j['name'] as String? ?? j['model'] as String? ?? '',
        size: (j['size'] as num?)?.toInt(),
        modifiedAt: j['modified_at'] as String?,
      );
}
