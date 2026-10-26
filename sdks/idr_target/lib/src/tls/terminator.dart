import 'dart:io';

/// Local TLS terminator abstraction — reload only; no cert issuance logic.
abstract class IdrTlsTerminator {
  /// Human-readable name.
  String get name;

  /// Reload after Certificate Manager materializes certs.
  Future<void> reload();
}

/// Default nginx terminator (`nginx -s reload`).
class NginxTerminator implements IdrTlsTerminator {
  const NginxTerminator({this.reloadCommand = const ['nginx', '-s', 'reload']});

  final List<String> reloadCommand;

  @override
  String get name => 'nginx';

  @override
  Future<void> reload() async {
    final r =
        await Process.run(reloadCommand.first, reloadCommand.skip(1).toList());
    if (r.exitCode != 0) {
      throw StateError('nginx reload failed (${r.exitCode}): ${r.stderr}');
    }
  }
}

/// HAProxy terminator — only knows how to reload; no cert-specific logic.
class HaproxyTerminator implements IdrTlsTerminator {
  const HaproxyTerminator({
    required this.reloadCommand,
  });

  final List<String> reloadCommand;

  @override
  String get name => 'haproxy';

  @override
  Future<void> reload() async {
    final r =
        await Process.run(reloadCommand.first, reloadCommand.skip(1).toList());
    if (r.exitCode != 0) {
      throw StateError('haproxy reload failed (${r.exitCode}): ${r.stderr}');
    }
  }
}

/// Fully custom reload argv (e.g. Windows service restart).
class CustomTerminator implements IdrTlsTerminator {
  const CustomTerminator({
    required this.name,
    required this.reloadCommand,
  });

  @override
  final String name;
  final List<String> reloadCommand;

  @override
  Future<void> reload() async {
    final r =
        await Process.run(reloadCommand.first, reloadCommand.skip(1).toList());
    if (r.exitCode != 0) {
      throw StateError('$name reload failed (${r.exitCode}): ${r.stderr}');
    }
  }
}
