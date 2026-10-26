import 'dart:io';

import 'package:idr_source/idr_source.dart';
import 'package:path/path.dart' as p;

/// CLI prefs directory: `%APPDATA%/idr` or `~/.config/idr`.
Directory cliConfigDirectory() {
  final appData = Platform.environment['APPDATA'];
  if (appData != null && appData.isNotEmpty) {
    return Directory(p.join(appData, 'idr'));
  }
  final home = Platform.environment['HOME'] ?? '.';
  return Directory(p.join(home, '.config', 'idr'));
}

/// Organizations this machine enrolled into (billing doesn't list them).
File get knownOrgsFile => File(p.join(cliConfigDirectory().path, 'orgs.json'));

/// File-backed [SourcePrefs] under the CLI config directory.
FileSourcePrefs createCliPrefs() =>
    FileSourcePrefs(directory: cliConfigDirectory());
