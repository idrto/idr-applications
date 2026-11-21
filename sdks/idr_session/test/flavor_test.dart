import 'package:idr_session/idr_session.dart';
import 'package:test/test.dart';

void main() {
  test('nativeSignIn defaults to true when the config omits it', () {
    expect(IdrFlavor.fromJson('prod', {'dev': false}).nativeSignIn, isTrue);
  });

  test('nativeSignIn reads an explicit value from the config', () {
    expect(IdrFlavor.fromJson('dev', {'nativeSignIn': false}).nativeSignIn,
        isFalse);
    expect(IdrFlavor.fromJson('dev', {'nativeSignIn': true}).nativeSignIn,
        isTrue);
  });
}
