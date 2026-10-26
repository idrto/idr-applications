/// Typed Source SDK failure with a stable string code and user message.
class IdrSourceException implements Exception {
  const IdrSourceException({
    required this.code,
    required this.message,
    this.cause,
  });

  /// Stable wire form (e.g. `AUTH_REQUIRED`, `CONNECT_FAILED`).
  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'IdrSourceException($code: $message)';
}

/// Something the developer/user must act on (non-fatal attention).
class SourceAttention {
  const SourceAttention({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'SourceAttention($code: $message)';
}
