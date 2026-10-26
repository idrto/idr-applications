import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/service_entry.dart';

/// Writes `target.local.toml`. [fqhn] must be API-verified.
class TomlWriter {
  TomlWriter({
    required this.fqhn,
    required this.agentRegion,
    required this.usingParty,
    required this.discoveryUrl,
    required this.discoveryKey,
    required this.services,
    this.payingParty,
    this.httpUpstream = '127.0.0.1:18080',
    this.tlsUpstream = '127.0.0.1:443',
    this.insecureDev = false,
    this.webrtcEnabled = true,
    this.entitlementJwtPath,
    this.identityKeyPath,
    this.dpIdentityPath,
    this.acmeEnabled = false,
    this.acmeDomains = const [],
    this.acmeEmail,
    this.acmeStaging = false,
    this.acmeWebroot,
    this.acmeCertDir,
    this.requireSourcePolicy = false,
  });

  final String fqhn;
  final String agentRegion;
  final String usingParty;
  final String? payingParty;
  final String discoveryUrl;
  final String discoveryKey;
  final List<IdrServiceEntry> services;
  final String httpUpstream;
  final String tlsUpstream;
  final bool insecureDev;
  final bool webrtcEnabled;
  final String? entitlementJwtPath;
  /// Agent Ed25519 key file — must match entitlement JWT `target_identity`.
  final String? identityKeyPath;
  final String? dpIdentityPath;
  final bool acmeEnabled;
  final List<String> acmeDomains;

  /// Let's Encrypt contact (the signed-in email).
  final String? acmeEmail;

  /// Let's Encrypt staging directory (development mode).
  final bool acmeStaging;

  /// HTTP-01 token files and issued certificates (under the config dir).
  final String? acmeWebroot;
  final String? acmeCertDir;

  /// `[webrtc.policy].require_source_policy` (Enterprise): only Presence-verified
  /// Sources may open streams, limited to their zone's services.
  final bool requireSourcePolicy;

  String toToml() {
    // Presence identity is `host--entity.idr.to` (email `@` ok) or classic dotted DNS.
    final f = canonicalPresenceFqhn(fqhn);
    if (f.isEmpty || (!f.contains('--') && !f.contains('.'))) {
      throw StateError('verified FQHN required for TOML');
    }
    // Never write native *.idr.to into [acme].domains
    final acmeHosts = acmeDomains
        .where((d) => !d.toLowerCase().endsWith('.idr.to'))
        .toList();

    final pay = payingParty == null || payingParty!.isEmpty
        ? ''
        : 'paying_party = "${_esc(payingParty!)}"\n';
    final buf = StringBuffer()
      ..writeln('[target]')
      ..writeln('fqhn = "${_esc(f)}"')
      ..writeln('agent_region = "${_esc(agentRegion)}"');
    if (identityKeyPath != null && identityKeyPath!.isNotEmpty) {
      buf.writeln('identity_key_path = "${_esc(identityKeyPath!)}"');
    }
    buf
      ..writeln()
      ..writeln('[billing_party]')
      ..writeln('using_party = "${_esc(usingParty)}"')
      ..write(pay)
      ..writeln();

    if (dpIdentityPath != null && dpIdentityPath!.isNotEmpty) {
      buf
        ..writeln('[dp]')
        ..writeln('identity_path = "${_esc(dpIdentityPath!)}"')
        ..writeln();
    }

    if (entitlementJwtPath != null && entitlementJwtPath!.isNotEmpty) {
      buf
        ..writeln('[auth]')
        ..writeln('entitlement_jwt_path = "${_esc(entitlementJwtPath!)}"')
        ..writeln();
    }

    buf
      ..writeln('[presence]')
      ..writeln('discovery_url = "${_esc(discoveryUrl)}"')
      ..writeln('discovery_key = "${_esc(discoveryKey)}"')
      ..writeln('prefer_quic = true')
      ..writeln('insecure_dev = $insecureDev')
      ..writeln('reconnect_initial_ms = 250')
      ..writeln('reconnect_max_seconds = 30')
      ..writeln('connect_timeout_seconds = 10')
      ..writeln()
      ..writeln('[nginx]')
      ..writeln('tls_upstream = "${_esc(tlsUpstream)}"')
      ..writeln('http_upstream = "${_esc(httpUpstream)}"')
      ..writeln('tunnel_enabled = true')
      ..writeln()
      ..writeln('[sqlite]')
      ..writeln('path = "target-agent.db"')
      ..writeln()
      ..writeln('[telemetry]')
      ..writeln('metrics_listen = "127.0.0.1:9091"')
      ..writeln('log_level = "info"')
      ..writeln()
      ..writeln('[shutdown]')
      ..writeln('grace_period_seconds = 10')
      ..writeln()
      ..writeln('[webrtc]')
      ..writeln('enabled = $webrtcEnabled')
      ..writeln('relay_mode = "platform"')
      // Local/dev: avoid stun.idr.to DNS hangs. Prod: google_and_idr.
      ..writeln(
        'stun_policy = "${insecureDev ? 'google_only' : 'google_and_idr'}"',
      )
      ..writeln('max_sessions = 64')
      ..writeln('turn_probe_enabled = true')
      ..writeln()
      ..writeln('[webrtc.policy]')
      ..writeln('deny_private_ips = ${insecureDev ? 'false' : 'true'}')
      ..writeln('allowed_tcp_connect_suffixes = []')
      ..writeln('require_source_policy = $requireSourcePolicy')
      ..writeln()
      ..writeln('[plugins]')
      ..writeln('http = true')
      ..writeln()
      ..writeln('[acme]')
      ..writeln('enabled = ${acmeEnabled && acmeHosts.isNotEmpty}');
    if (acmeEnabled && acmeHosts.isNotEmpty) {
      buf.writeln(
        'domains = [${acmeHosts.map((d) => '"${_esc(d)}"').join(', ')}]',
      );
      final email = acmeEmail?.trim();
      if (email != null && email.isNotEmpty) {
        buf.writeln('email = "${_esc(email)}"');
      }
      buf.writeln('staging = $acmeStaging');
      if (acmeWebroot != null) {
        buf.writeln('webroot = "${_esc(acmeWebroot!)}"');
      }
      if (acmeCertDir != null) {
        buf.writeln('cert_dir = "${_esc(acmeCertDir!)}"');
      }
      // The Target answers HTTP-01 itself; don't fail installs where no nginx runs.
      buf.writeln('nginx_reload_command = ""');
    }
    buf.writeln();

    for (final s in services) {
      buf
        ..writeln('[[services]]')
        ..writeln('name = "${_esc(s.name)}"')
        ..writeln('type = "${_esc(s.type)}"')
        ..writeln('enabled = ${s.enabled}');
      if (s.baseUrl != null && s.baseUrl!.isNotEmpty) {
        buf.writeln('base_url = "${_esc(s.baseUrl!)}"');
      }
      if (s.host != null && s.host!.isNotEmpty) {
        buf.writeln('host = "${_esc(s.host!)}"');
      }
      if (s.port != null) {
        buf.writeln('port = ${s.port}');
      }
      buf.writeln('credential_mode = "${_esc(s.credentialMode)}"');
      if (s.requireUpstreamTls != null) {
        buf.writeln('require_upstream_tls = ${s.requireUpstreamTls}');
      }
      final env = s.authEnvVar?.trim();
      if (env != null && env.isNotEmpty) {
        buf
          ..writeln('inject_headers = [')
          ..writeln(
            '  { name = "${_esc(s.authHeaderName)}", from_env = "${_esc(env)}", '
            'prefix = "${_esc(s.authPrefix)}" },',
          )
          ..writeln(']');
      }
      buf.writeln();
    }
    return buf.toString();
  }

  Future<File> writeTo(Directory dir) async {
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final file = File(p.join(dir.path, 'target.local.toml'));
    await file.writeAsString(toToml());
    return file;
  }

  static String _esc(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}

/// `{host}--{entity}` → `{host}--{entity}.idr.to`. Already-suffixed and dotted DNS unchanged.
String canonicalPresenceFqhn(String fqhn) {
  var s = fqhn.trim().toLowerCase();
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  if (s.contains('--') && !s.endsWith('.idr.to')) {
    return '$s.idr.to';
  }
  return s;
}
