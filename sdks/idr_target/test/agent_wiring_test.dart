import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:idr_target/src/agent/agent_runtime.dart';
import 'package:idr_target/src/agent/process_manager.dart';
import 'package:idr_target/src/auth/auth.dart';
import 'package:idr_target/src/config.dart';
import 'package:idr_target/src/crypto/idr_crypto.dart';
import 'package:idr_target/src/entitlement/agent_token_client.dart';
import 'package:idr_target/src/entitlement/token_refresher.dart';
import 'package:test/test.dart';

import 'support/memory_storage.dart';

class _FakeCrypto implements IdrCrypto {
  @override
  Ed25519KeyMaterial generateEd25519() => throw UnimplementedError();

  @override
  String buildCsr({required String privatePem, required String fqhn}) =>
      throw UnimplementedError();

  @override
  String sign({required String privatePem, required List<int> message}) =>
      throw UnimplementedError();

  @override
  String signJson({required String privatePem, required String json}) =>
      throw UnimplementedError();

  @override
  String ski(String publicB64url) => 'ski';

  @override
  ({String leafPem, String chainPem}) signCsr({
    required String csrPem,
    required Map<String, dynamic> caPrivateJwk,
    required String issuerSki,
    String? host,
    String? issuerChainPem,
  }) =>
      throw UnimplementedError();

  @override
  String signIntermediateCa({
    required Map<String, dynamic> childPublicJwk,
    required String childCommonName,
    required Map<String, dynamic> parentPrivateJwk,
    required String parentCommonName,
  }) =>
      throw UnimplementedError();

  @override
  String caCertPemFromPrivateJwk({
    required Map<String, dynamic> privateJwk,
    required String commonName,
  }) =>
      throw UnimplementedError();
}

String _fakePkcs8Pem() {
  final der = Uint8List.fromList([
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70,
    0x04, 0x22, 0x04, 0x20,
    ...List<int>.filled(32, 1),
  ]);
  final b64 = base64Encode(der);
  return '-----BEGIN PRIVATE KEY-----\n$b64\n-----END PRIVATE KEY-----\n';
}

class _SilentProcess extends ProcessManager {
  @override
  Future<void> start({
    required String binaryPath,
    required String configPath,
    String? workingDirectory,
    Map<String, String>? injectEnv,
    String? entitlementJwt,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  group('TokenRefresher', () {
    test('invokes onRefreshed when the JWT is reminted', () async {
      final store = SessionStore(storage: MemoryStorage());
      final client = AgentTokenClient(
        apiBaseUrl: 'http://127.0.0.1:1',
        store: store,
        crypto: _FakeCrypto(),
      );
      final next = EntitlementToken(
        token: 'fresh-jwt',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      final received = <EntitlementToken>[];
      final refresher = TokenRefresher(
        client: client,
        mint: () async => next,
        onRefreshed: (token) async {
          received.add(token);
        },
      );
      refresher.start(
        EntitlementToken(
          token: 'stale-jwt',
          expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      refresher.stop();
      expect(received, hasLength(1));
      expect(received.single.token, 'fresh-jwt');
    });
  });

  group('AgentRuntime.start', () {
    test('writes identity.dp.json when start receives identity JSON', () async {
      final dir = await Directory.systemTemp.createTemp('idr-agent-runtime-');
      addTearDown(() => dir.delete(recursive: true));
      final dummyBin = File('${dir.path}${Platform.pathSeparator}dummy-agent');
      await dummyBin.writeAsString('');

      final runtime = AgentRuntime(
        config: IdrTargetConfig(
          controlPlaneUrl: Uri.parse('http://127.0.0.1:1'),
          agentBinaryPath: dummyBin.path,
          configDirectory: dir.path,
          mode: IdrTargetMode.development,
        ),
        configDir: () => dir,
        processManager: _SilentProcess(),
      );

      const identityJson = '{"ski":"abc","credential":{"ski":"abc"}}';
      await runtime.start(
        verifiedFqhn: 'laptop--user@example.com.idr.to',
        usingParty: 'user@example.com',
        entitlement: EntitlementToken(
          token: 'jwt',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
        services: const [],
        targetIdentityPem: _fakePkcs8Pem(),
        targetIdentityPublicB64url: 'A' * 43,
        dpIdentityJson: identityJson,
      );

      final written = File('${dir.path}${Platform.pathSeparator}identity.dp.json');
      expect(written.existsSync(), isTrue);
      expect(await written.readAsString(), identityJson);
      final toml = await File('${dir.path}${Platform.pathSeparator}target.local.toml')
          .readAsString();
      expect(toml, contains('identity_path'));
      await runtime.dispose();
    });
  });
}
