import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_session/idr_session.dart';
import 'package:idr_telemetry/idr_telemetry.dart';
import 'package:test/test.dart';

void main() {
  test('sends traceparent, records method/status/x-request-id, never the query', () async {
    final root = Directory.systemTemp.createTempSync('idr_http_');
    addTearDown(() => root.deleteSync(recursive: true));
    await Telemetry.init(TelemetryConfig(service: 'idr_test', serviceVersion: 't', logRoot: root.path, filter: 'debug'));
    String? sent;
    final client = TracedHttpClient(MockClient((req) async {
      sent = req.headers['traceparent'];
      return http.Response('{}', 200, headers: {'x-request-id': 'req-123'});
    }));
    await client.get(Uri.parse('https://api.example.com/api/v1/custom-domains?targetFqhn=laptop--a%40b.idr.to&token=abc'));
    await Telemetry.shutdown();
    final tp = TraceContext.parse(sent ?? '');
    expect(tp, isNotNull, reason: 'a valid W3C traceparent was sent');
    final lines = [
      for (final f in Directory('${root.path}${Platform.pathSeparator}idr_test').listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')))
        ...const LineSplitter().convert(f.readAsStringSync()),
    ];
    final span = lines.map((l) => jsonDecode(l) as Map<String, Object?>).singleWhere((r) => r['event'] == 'http.client.request' && r['kind'] == 'span');
    final a = span['attrs'] as Map;
    expect(a['http.response.status_code'], 200);
    expect(a['http.request_id'], 'req-123');
    expect(a['http.request.method'], 'GET');
    expect(a['url.path'], '/api/v1/custom-domains');
    expect(a['server.port'], 443);
    expect(span['span_id'], tp!.spanId, reason: 'the header carries this span');
    expect(lines.join(), isNot(contains('targetFqhn')));
    expect(lines.join(), isNot(contains('token=abc')));
  });

  test('route templates hide identifiers and the query is never logged', () {
    expect(routeTemplate('/api/v1/custom-domains'), '/api/v1/custom-domains');
    expect(routeTemplate('/api/v1/entities/0193ab12-aaaa/members/alice@example.com'), '/api/v1/entities/{id}/members/{id}');
    expect(routeTemplate('/api/v1/targets/laptop--x.idr.to'), '/api/v1/targets/{id}');
  });

  test('without telemetry it is a plain pass-through', () async {
    final client = TracedHttpClient(MockClient((req) async {
      expect(req.headers.containsKey('traceparent'), isFalse);
      return http.Response('ok', 200);
    }));
    expect((await client.get(Uri.parse('https://x.test/'))).body, 'ok');
  });
}
