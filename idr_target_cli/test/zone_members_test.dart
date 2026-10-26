import 'package:idr_target_cli/modes/enterprise.dart';
import 'package:test/test.dart';

void main() {
  test('zone members: that zone only, Targets and Sources, not zone CAs', () {
    final credentials = [
      {'ski': 'a', 'host': 'alice', 'kind': 'machine_source', 'zone': 'fin'},
      {'ski': 'b', 'host': 'gpu', 'kind': 'machine_target', 'zone': 'fin'},
      {'ski': 'c', 'host': null, 'kind': 'zone_authority', 'zone': 'fin'},
      {'ski': 'd', 'host': 'bob', 'kind': 'machine_source', 'zone': 'fin.apac'},
      {'ski': 'e', 'host': 'root-box', 'kind': 'machine_target', 'zone': null},
    ];
    expect([for (final m in zoneMembers(credentials, 'fin')) m['ski']],
        ['a', 'b']);
    expect([for (final m in zoneMembers(credentials, 'fin.apac')) m['ski']],
        ['d']);
    expect(zoneMembers(credentials, 'hr'), isEmpty);
  });
}
