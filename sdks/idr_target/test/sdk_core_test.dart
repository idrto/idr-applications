import 'package:idr_target/src/agent/toml_writer.dart';
import 'package:idr_target/src/crypto/idr_crypto.dart';
import 'package:idr_target/src/internal/backoff.dart';
import 'package:idr_target/src/services/service_entry.dart';
import 'package:idr_target/src/tls/certificate_manager.dart';
import 'package:idr_target/src/tls/terminator.dart';
import 'package:idr_target/src/tls/tls_status.dart';
import 'package:test/test.dart';

class _NoopTerminator implements IdrTlsTerminator {
  @override
  String get name => 'noop';

  @override
  Future<void> reload() async {}
}

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

void main() {
  group('Backoff', () {
    test('advances attempt counter', () {
      final b = Backoff(
        initial: const Duration(milliseconds: 50),
        max: const Duration(milliseconds: 200),
      );
      expect(b.attempt, 0);
      b.next();
      expect(b.attempt, 1);
      b.reset();
      expect(b.attempt, 0);
    });
  });

  group('TomlWriter', () {
    test('requires verified FQHN', () {
      final w = TomlWriter(
        fqhn: 'laptop',
        agentRegion: 'eu',
        usingParty: 'a@b.c',
        discoveryUrl: 'https://example/x',
        discoveryKey: 'k',
        services: [],
      );
      expect(w.toToml, throwsStateError);
    });

    test('writes verified FQHN and strips *.idr.to from acme domains', () {
      final w = TomlWriter(
        fqhn: 'laptop.alice-acme-com.idr.to',
        agentRegion: 'eu-central',
        usingParty: 'alice@acme.com',
        discoveryUrl: 'https://public.idr.to/.well-known/idr-presence.json',
        discoveryKey: 'key',
        services: [
          IdrServiceEntry(name: 'ollama', baseUrl: 'http://127.0.0.1:11434'),
        ],
        acmeEnabled: true,
        acmeDomains: ['laptop.alice-acme-com.idr.to', 'app.customer.com'],
      );
      final toml = w.toToml();
      expect(toml, contains('fqhn = "laptop.alice-acme-com.idr.to"'));
      expect(toml, contains('app.customer.com'));
      expect(
        RegExp(r'\[acme\][\s\S]*?domains = \[[^\]]*laptop\.alice')
            .hasMatch(toml),
        isFalse,
      );
      expect(toml, contains('[[services]]'));
    });

    test('writes require_source_policy under [webrtc.policy]', () {
      String tomlFor({bool? require}) => (require == null
              ? TomlWriter(
                  fqhn: 'laptop--a@acme.test.idr.to',
                  agentRegion: 'eu',
                  usingParty: 'a@acme.test',
                  discoveryUrl: 'https://example/x',
                  discoveryKey: 'k',
                  services: [],
                )
              : TomlWriter(
                  fqhn: 'laptop--a@acme.test.idr.to',
                  agentRegion: 'eu',
                  usingParty: 'a@acme.test',
                  discoveryUrl: 'https://example/x',
                  discoveryKey: 'k',
                  services: [],
                  requireSourcePolicy: require,
                ))
          .toToml();
      final policy = RegExp(r'\[webrtc\.policy\]([\s\S]*?)\n\[');
      expect(policy.firstMatch(tomlFor(require: true))!.group(1),
          contains('require_source_policy = true'));
      expect(policy.firstMatch(tomlFor())!.group(1),
          contains('require_source_policy = false'));
    });

    test('writes [acme] for custom domains only when there are some', () {
      String acmeBlock(List<String> domains) => RegExp(r'\[acme\]\n([\s\S]*?)\n\n')
          .firstMatch(TomlWriter(
            fqhn: 'box--a@acme.test.idr.to',
            agentRegion: 'eu',
            usingParty: 'a@acme.test',
            discoveryUrl: 'https://example/x',
            discoveryKey: 'k',
            services: [],
            acmeEnabled: domains.isNotEmpty,
            acmeDomains: domains,
            acmeEmail: 'a@acme.test',
            acmeStaging: true,
            acmeWebroot: r'C:\cfg\acme\webroot',
            acmeCertDir: r'C:\cfg\acme\certs',
          ).toToml())!
          .group(1)!;
      final on = acmeBlock(['app.customer.com', 'box--a@acme.test.idr.to']);
      expect(on, contains('enabled = true'));
      expect(on, contains('domains = ["app.customer.com"]'),
          reason: 'never *.idr.to');
      expect(on, contains('email = "a@acme.test"'));
      expect(on, contains('staging = true'));
      expect(on, contains(r'webroot = "C:\\cfg\\acme\\webroot"'));
      expect(on, contains(r'cert_dir = "C:\\cfg\\acme\\certs"'));
      expect(on, contains('nginx_reload_command = ""'));
      expect(acmeBlock([]).trim(), 'enabled = false');
    });
  });

  group('TLS Phase 1', () {
    test('native idr.to → relayTerminated', () async {
      final mgr = CertificateManager(
        crypto: _FakeCrypto(),
        terminator: _NoopTerminator(),
        certDir: '.',
        apiBaseUrl: 'http://127.0.0.1:3000',
      );
      final s = await mgr.ensurePhase1Native('laptop.user.idr.to');
      expect(s, IdrTlsStatus.relayTerminated);
      expect(mgr.isNativeIdrFqhn('cam.acme.idr.to'), isTrue);
      expect(mgr.isNativeIdrFqhn('app.example.com'), isFalse);
    });
  });
}
