import 'package:idr_service_http/idr_service_http.dart';

/// OpenAI-compatible model entry from Target HF allowlist (`GET /v1/models`).
class HfModelInfo {
  HfModelInfo({
    required this.id,
    this.modality = 'chat',
    this.ownedBy = 'huggingface',
  });

  final String id;
  final String modality;
  final String ownedBy;

  bool get isImage =>
      modality == 'image' || modality == 'text-to-image';

  bool get isChat => !isImage;

  factory HfModelInfo.fromJson(Map<String, dynamic> json) {
    return HfModelInfo(
      id: (json['id'] as String?) ?? '',
      modality: (json['modality'] as String?) ?? 'chat',
      ownedBy: (json['owned_by'] as String?) ?? 'huggingface',
    );
  }
}

class HfChatRequest {
  HfChatRequest({
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

class HfChatResponse {
  HfChatResponse({
    required this.id,
    required this.model,
    required this.content,
  });

  final String id;
  final String model;
  final String content;

  factory HfChatResponse.fromJson(Map<String, dynamic> json) {
    final choices = json['choices'];
    var content = '';
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final message = first['message'];
        if (message is Map) {
          content = (message['content'] as String?) ?? '';
        }
      }
    }
    return HfChatResponse(
      id: (json['id'] as String?) ?? '',
      model: (json['model'] as String?) ?? '',
      content: content,
    );
  }
}

/// Result of Target → HF text-to-image (`POST /v1/images/generations`).
class HfImageResult {
  HfImageResult({
    required this.bytes,
    this.mime = 'image/jpeg',
  });

  final List<int> bytes;
  final String mime;
}
