import 'dart:io';

import 'package:idr_session/idr_session.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('idr_auth_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('round trip; encrypted on Windows; concurrent writers lose nothing', () async {
    final file = File('${tmp.path}/secure/auth.json');
    final a = FileAuthStorage(file: file);
    final b = FileAuthStorage(file: file); // a second process sharing the file
    await Future.wait([
      for (var i = 0; i < 20; i++) (i.isEven ? a : b).setItem('k$i', 'secret-$i'),
    ]);
    for (var i = 0; i < 20; i++) {
      expect(await b.getItem('k$i'), 'secret-$i');
    }
    await a.removeItem('k0');
    expect(await b.getItem('k0'), isNull);
    final raw = file.readAsBytesSync();
    expect(raw.first == 0x7B, !Platform.isWindows, reason: 'plain JSON only off Windows');
  });
}
