import 'dart:io';

import 'package:path/path.dart' as p;

/// Native library basename for the current platform.
String nativeLibraryBasename() {
  if (Platform.isWindows) return 'idr_c_api.dll';
  if (Platform.isMacOS) return 'libidr_c_api.dylib';
  return 'libidr_c_api.so';
}

bool libraryFileExists(String path) => File(path).existsSync();

/// Resolve library path: explicit → `IDR_C_API_LIB` → next to the executable →
/// walk up (from cwd, then
/// the executable) for `agents_engine/agent/target/{release,debug}/<lib>`
/// (legacy `agent/target/...` too).
String? resolveLibraryPath(String? configured) {
  final fromConfig = configured?.trim();
  if (fromConfig != null && fromConfig.isNotEmpty) {
    return fromConfig;
  }

  final fromEnv = Platform.environment['IDR_C_API_LIB']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }

  final basename = nativeLibraryBasename();
  // Also accept bare idr_c_api.so / .dylib without lib prefix on some builds.
  final candidates = <String>{
    basename,
    if (Platform.isWindows) 'idr_c_api.dll',
    if (!Platform.isWindows) 'idr_c_api.so',
    if (Platform.isMacOS) 'idr_c_api.dylib',
  };
  // Shipped CLIs keep the library next to the executable.
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  for (final name in candidates) {
    final f = File(p.join(exeDir, name));
    if (f.existsSync()) return f.path;
  }

  const agentDirs = [
    ['agents_engine', 'agent'],
    ['agent'],
  ];

  for (final start in [
    Directory.current,
    File(Platform.resolvedExecutable).parent,
  ]) {
    var dir = start;
    for (var i = 0; i < 12; i++) {
      for (final agent in agentDirs) {
        for (final profile in const ['release', 'debug']) {
          for (final name in candidates) {
            final f = File(
              p.joinAll([dir.path, ...agent, 'target', profile, name]),
            );
            if (f.existsSync()) return f.path;
          }
        }
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }

  return null;
}
