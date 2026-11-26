import 'package:idr_target/src/agent/toml_writer.dart';
import 'package:idr_target/src/services/service_entry.dart';
import 'package:idr_target/src/services/services_manager.dart';
import 'package:test/test.dart';

void main() {
  TomlWriter writer(List<IdrServiceEntry> services, {String? key}) => TomlWriter(
        fqhn: 'laptop--a@b.com.idr.to',
        agentRegion: 'local',
        usingParty: 'a@b.com',
        discoveryUrl: 'https://x/.well-known/idr-presence.json',
        discoveryKey: 'k',
        services: services,
        webAccessKey: key,
      );

  test('web services write web_path, web_access and [web]', () {
    final toml = writer([
      IdrServiceEntry(
        name: 'ollama',
        baseUrl: 'http://127.0.0.1:11434',
        webPath: '/ollama',
      ),
      IdrServiceEntry(
        name: 'site',
        baseUrl: 'http://127.0.0.1:3000',
        webPath: '/',
        webAccess: 'public',
      ),
    ], key: 'secret-key-0123456789').toToml();
    expect(toml, contains('[web]\naccess_key = "secret-key-0123456789"'));
    expect(toml, contains('web_path = "/ollama"\nweb_access = "private"'));
    expect(toml, contains('web_path = "/"\nweb_access = "public"'));
  });

  test('without web services nothing changes (personal / enterprise)', () {
    final toml = writer([
      IdrServiceEntry(name: 'ollama', baseUrl: 'http://127.0.0.1:11434'),
    ], key: 'secret-key-0123456789').toToml();
    expect(toml, isNot(contains('[web]')));
    expect(toml, isNot(contains('web_path')));
  });

  test('paths normalize like the agent', () {
    expect(ServicesManager.normalizeWebPath(''), '/');
    expect(ServicesManager.normalizeWebPath('ollama/'), '/ollama');
    expect(ServicesManager.normalizeWebPath('/a/b'), '/a/b');
    expect(ServicesManager.normalizeWebPath('/../x'), isNull);
    expect(ServicesManager.normalizeWebPath('a b'), isNull);
  });
}
