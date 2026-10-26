/// One chat turn (`system` | `user` | `assistant`).
class ChatTurn {
  const ChatTurn({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};

  factory ChatTurn.fromJson(Map<String, dynamic> j) => ChatTurn(
        role: j['role'] as String? ?? 'assistant',
        content: j['content'] as String? ?? '',
      );
}
