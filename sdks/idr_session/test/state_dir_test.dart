import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Each probe runs with a temporary APPDATA/HOME, never the user's profile.
void main() {
  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('idr_state_'));
  tearDown(() => base.deleteSync(recursive: true));

  Future<Map<String, dynamic>> resolve(String flavor) async {
    final r = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'test/state_dir_probe.dart', flavor],
      environment: Platform.isWindows
          ? {'APPDATA': base.path}
          : {'APPDATA': '', 'HOME': base.path},
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return jsonDecode('${r.stdout}') as Map<String, dynamic>;
  }

  String root() => Platform.isWindows
      ? base.path
      : p.join(base.path, '.config');

  for (final flavor in ['prod', 'dev', 'staging']) {
    test('$flavor resolves separate source and target paths without creating state', () async {
      final suffix = flavor == 'prod' ? '' : '-$flavor';
      expect(await resolve(flavor), {
        'source': p.join(root(), 'idr.to', 'source$suffix'),
        'target': p.join(root(), 'idr.to', 'target$suffix'),
      });
      expect(base.listSync(), isEmpty);
    });
  }

  test('resolving paths leaves existing directories and files untouched', () async {
    final existing = Directory(p.join(root(), 'existing-profile'))
      ..createSync(recursive: true);
    final marker = File(p.join(existing.path, 'auth.json'))
      ..writeAsStringSync('unchanged');
    final target = Directory(p.join(root(), 'idr.to', 'target'))
      ..createSync(recursive: true);
    final targetMarker = File(p.join(target.path, 'marker'))
      ..writeAsStringSync('target');

    expect((await resolve('prod'))['target'], target.path);
    expect(marker.readAsStringSync(), 'unchanged');
    expect(targetMarker.readAsStringSync(), 'target');
    expect(Directory(p.join(root(), 'idr.to', 'source')).existsSync(), isFalse);
  });
}
