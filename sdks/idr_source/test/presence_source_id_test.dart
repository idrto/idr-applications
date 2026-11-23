import 'package:idr_source/src/identity/presence_source_id.dart';
import 'package:test/test.dart';

void main() {
  test('uses the device ski, never an email', () {
    expect(presenceSourceId('{"ski":"abc123ski","credential":{"x":1}}'), 'abc123ski');
  });

  test('reads the ski nested in the stored CLI identity', () {
    expect(presenceSourceId('{"credential":{"ski":"nested-ski"}}'), 'nested-ski');
  });

  test('falls back to a constant without a device identity or a usable ski', () {
    expect(presenceSourceId(null), 'dart');
    expect(presenceSourceId('not json'), 'dart');
    expect(presenceSourceId('{"credential":{}}'), 'dart');
    expect(presenceSourceId('{"ski":""}'), 'dart');
    expect(presenceSourceId('{"ski":42}'), 'dart');
  });

  test('an email can never be produced', () {
    for (final j in [null, '{"email":"bob@example.com"}', '{"ski":"s"}', '[]']) {
      expect(presenceSourceId(j), isNot(contains('@')));
    }
  });
}
