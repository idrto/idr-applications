import 'package:idr_target_cli/core/target.dart';
import 'package:test/test.dart';

void main() {
  test('org slugs: names, domains and emails pass; spaces and personal fail',
      () {
    for (final ok in ['acme', 'acme.com', 'a@b.com', 'fin-apac']) {
      expect(orgSlugProblem(ok), isNull, reason: ok);
    }
    expect(orgSlugProblem('acme corp'), contains('no spaces'));
    expect(orgSlugProblem('me'), contains('Personal setup'));
    expect(orgSlugProblem('personal'), contains('Personal setup'));
  });
}
