import 'dart:io';

import 'package:idr_source/idr_source.dart';
import 'package:path/path.dart' as p;

/// CLI prefs directory: `%APPDATA%/idr.to-s` or `~/.config/idr.to-s` (per flavor).
Directory cliConfigDirectory() => idrSourceDirectory;

/// Organizations this machine enrolled into (billing doesn't list them).
File get knownOrgsFile => File(p.join(cliConfigDirectory().path, 'orgs.json'));

/// File-backed [SourcePrefs] under the CLI config directory.
FileSourcePrefs createCliPrefs() =>
    FileSourcePrefs(directory: cliConfigDirectory());
