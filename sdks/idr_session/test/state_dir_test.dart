import 'dart:io';

import 'package:idr_session/idr_session.dart';
import 'package:test/test.dart';

/// [idrStateDirectory] reads `APPDATA`/`HOME` from the environment, so each
/// case runs state_dir_probe.dart in a child process with a temp base folder.
void main() {
  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('idr_state_'));
  tearDown(() => base.deleteSync(recursive: true));

  Future<String> resolve() async {
    final r = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'test/state_dir_probe.dart'],
      environment: Platform.isWindows
          ? {'APPDATA': base.path}
          : {'APPDATA': '', 'HOME': base.path},
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return '${r.stdout}';
  }

  String root() => Platform.isWindows
      ? base.path
      : '${base.path}${Platform.pathSeparator}.config';

  test('moves the legacy folder and keeps its files', () async {
    final old = Directory('${root()}${Platform.pathSeparator}old')
      ..createSync(recursive: true);
    File('${old.path}${Platform.pathSeparator}auth.json').writeAsStringSync('x');

    final dir = await resolve();
    expect(dir, '${root()}${Platform.pathSeparator}idr.to-t');
    expect(File('$dir${Platform.pathSeparator}auth.json').readAsStringSync(), 'x');
    expect(old.existsSync(), isFalse);
  });

  test('new folder wins when both exist', () async {
    Directory('${root()}${Platform.pathSeparator}old').createSync(recursive: true);
    Directory('${root()}${Platform.pathSeparator}idr.to-t').createSync(recursive: true);

    expect(await resolve(), '${root()}${Platform.pathSeparator}idr.to-t');
    expect(Directory('${root()}${Platform.pathSeparator}old').existsSync(), isTrue);
  });
}
