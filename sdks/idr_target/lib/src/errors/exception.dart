import 'codes.dart';
import 'messages.dart';

/// Typed SDK failure with a stable error code and user message.
class IdrTargetException implements Exception {
  const IdrTargetException({
    required this.code,
    required this.message,
    this.cause,
  });

  factory IdrTargetException.forCode(
    IdrTargetErrorCode code, {
    String? message,
    Object? cause,
  }) =>
      IdrTargetException(
        code: code,
        message: message ?? IdrTargetErrorMessages.of(code),
        cause: cause,
      );

  final IdrTargetErrorCode code;
  final String message;
  final Object? cause;

  /// Stable wire form (e.g. `AUTH_REQUIRED`).
  String get wire => code.wire;

  @override
  String toString() => 'IdrTargetException(${code.wire}: $message)';
}
