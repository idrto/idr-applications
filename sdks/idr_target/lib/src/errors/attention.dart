import 'codes.dart';

/// Something the developer/user must act on.
class IdrTargetAttention {
  const IdrTargetAttention({
    required this.code,
    required this.message,
  });

  final IdrTargetErrorCode code;
  final String message;

  @override
  String toString() => 'IdrTargetAttention(${code.wire}: $message)';
}
