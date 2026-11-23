import 'dart:convert';
import 'dart:io';

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

  test('agentConsoleLogs is off unless the config turns it on', () {
    expect(IdrFlavor.fromJson('prod', {'dev': false}).agentConsoleLogs, isFalse);
    expect(IdrFlavor.fromJson('dev', {'agentConsoleLogs': true}).agentConsoleLogs, isTrue);
    expect(IdrFlavor.fromJson('dev', {'agentConsoleLogs': 'yes'}).agentConsoleLogs, isFalse, reason: 'only a real true');
  });

  test('the shipped flavors: dev shows agent logs on the console, prod and staging do not', () {
    Map<String, Object?> cfg(String n) {
      final dir = Directory.current.path.endsWith('idr_session') ? '../../config' : 'config';
      return jsonDecode(File('$dir/$n.json').readAsStringSync()) as Map<String, Object?>;
    }
    expect(IdrFlavor.fromJson('dev', cfg('dev')).agentConsoleLogs, isTrue);
    expect(IdrFlavor.fromJson('prod', cfg('prod')).agentConsoleLogs, isFalse);
    expect(IdrFlavor.fromJson('staging', cfg('staging')).agentConsoleLogs, isFalse);
  });
}
