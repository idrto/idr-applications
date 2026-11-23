import 'package:http/http.dart' as http;
import 'package:idr_telemetry/idr_telemetry.dart';

const _log = IdrLog('idr_session.http');

/// An `http.Client` that records each request as the span `http.client.request` and sends
/// its W3C `traceparent` (docs/observability/01 §4). The response `x-request-id` is kept as
/// `http.request_id`.
///
/// Recorded: method, host and port, the endpoint as a route template (`url.path`, with ID-like
/// segments replaced by `{id}` and no query), status, duration, and on failure the redacted
/// reason. Never the query, headers or bodies. Without an initialised Telemetry it is a plain
/// pass-through.
class TracedHttpClient extends http.BaseClient {
  TracedHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (Telemetry.instance == null) return _inner.send(request);
    final url = request.url;
    return _log.span('http.client.request', (s) async {
      request.headers['traceparent'] = s.context.toTraceparent();
      try {
        final res = await _inner.send(request);
        s.set('http.response.status_code', res.statusCode);
        final rid = res.headers['x-request-id'];
        if (rid != null && rid.isNotEmpty && rid.length <= 128) s.set('http.request_id', rid);
        if (res.statusCode >= 500) s.fail('http_${res.statusCode}');
        return res;
      } on Object catch (e) {
        // The message is redacted by the pipeline (emails, IPs, paths, tokens).
        s.fail(e is http.ClientException ? 'http_client_error' : 'network_error', message: _reason(e));
        rethrow;
      }
    }, attrs: {
      'http.request.method': request.method,
      'server.address': url.host,
      'server.port': url.port,
      'url.path': routeTemplate(url.path),
    });
  }

  @override
  void close() => _inner.close();
}

/// `/api/v1/entities/0193…/members/a@b.c` → `/api/v1/entities/{id}/members/{id}`: a segment
/// with `@`, `.` or `%`, two or more digits, or more than 32 characters is an identifier
/// (so `v1` stays, numeric and UUID IDs do not).
String routeTemplate(String path) {
  bool isId(String seg) =>
      seg.contains(RegExp(r'[@.%]')) || RegExp(r'[0-9]').allMatches(seg).length >= 2 || seg.length > 32;
  return path.split('/').map((seg) => seg.isNotEmpty && isId(seg) ? '{id}' : seg).join('/');
}

/// The useful part of a client error: `SocketException: …refused…` without the full URI
/// (which may carry a query).
String _reason(Object e) {
  final text = e.toString();
  final cut = text.indexOf(', uri=');
  return cut < 0 ? text : text.substring(0, cut);
}
