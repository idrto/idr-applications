import 'dart:convert';
import 'dart:typed_data';

import 'package:idr_client/idr_client.dart';

/// Opens `openStream(serviceName)` and exchanges raw HTTP/1.1 with Target gateway.
///
/// [hostHeader] should match the Target upstream (e.g. `127.0.0.1:11434`) so
/// local servers that validate Host succeed. Target may inject secrets.
class IdrServiceHttpClient {
  IdrServiceHttpClient(
    this.session, {
    required this.serviceName,
    required this.hostHeader,
  });

  final IdrSession session;
  final String serviceName;
  final String hostHeader;

  static const _poll = Duration(milliseconds: 10);

  Future<Map<String, dynamic>> httpJson({
    required String method,
    required String path,
    String body = '',
    int maxRead = 12 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 120),
    bool Function(String body)? bodyLooksComplete,
  }) async {
    final stream = await session.openStream(serviceName);
    try {
      final httpReq = _buildHttpRequest(method: method, path: path, body: body);
      await stream.write(Uint8List.fromList(utf8.encode(httpReq)));

      final chunks = <int>[];
      final deadline = DateTime.now().add(timeout);
      var emptyStreak = 0;
      while (DateTime.now().isBefore(deadline) && chunks.length < maxRead) {
        final part = await stream.read(maxLen: 65536);
        if (part.isEmpty) {
          emptyStreak++;
          if (chunks.isNotEmpty) {
            final text = utf8.decode(chunks);
            if (_httpBodyComplete(text, bodyLooksComplete) || emptyStreak >= 8) {
              break;
            }
          } else if (emptyStreak >= 40) {
            break;
          }
          await Future<void>.delayed(_poll);
          continue;
        }
        emptyStreak = 0;
        chunks.addAll(part);
        final text = utf8.decode(chunks);
        if (_httpBodyComplete(text, bodyLooksComplete)) break;
      }
      await stream.halfClose();

      final raw = utf8.decode(chunks);
      final status = _httpStatus(raw);
      final jsonBody = _extractHttpBody(raw);
      if (status != null && (status < 200 || status >= 300)) {
        throw StateError(
          'HTTP $status: ${jsonBody.isEmpty ? '(empty body)' : jsonBody}',
        );
      }
      if (jsonBody.trim().isEmpty) {
        throw StateError('Empty body (HTTP ${status ?? '?'})');
      }
      final decoded = jsonDecode(jsonBody);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw StateError('Expected JSON object');
    } catch (e) {
      try {
        await stream.reset(reason: 1);
      } catch (_) {}
      rethrow;
    }
  }

  /// Yields each NDJSON object from a streaming HTTP response body.
  Stream<Map<String, dynamic>> httpNdjson({
    required String method,
    required String path,
    String body = '',
    int maxRead = 12 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 180),
  }) async* {
    final stream = await session.openStream(serviceName);
    try {
      final httpReq = _buildHttpRequest(method: method, path: path, body: body);
      await stream.write(Uint8List.fromList(utf8.encode(httpReq)));

      final chunks = <int>[];
      var headerDone = false;
      var bodyOffset = 0;
      var lineStart = 0;
      final deadline = DateTime.now().add(timeout);
      var emptyStreak = 0;
      var done = false;

      while (!done &&
          DateTime.now().isBefore(deadline) &&
          chunks.length < maxRead) {
        final part = await stream.read(maxLen: 65536);
        if (part.isEmpty) {
          emptyStreak++;
          if (headerDone && emptyStreak >= 80) break;
          if (!headerDone && emptyStreak >= 40) break;
          await Future<void>.delayed(_poll);
          continue;
        }
        emptyStreak = 0;
        chunks.addAll(part);

        if (!headerDone) {
          final raw = utf8.decode(chunks, allowMalformed: true);
          final sep = raw.indexOf('\r\n\r\n');
          if (sep < 0) continue;
          final status = _httpStatus(raw);
          if (status != null && (status < 200 || status >= 300)) {
            throw StateError(
              'HTTP $status: ${_extractHttpBody(raw)}',
            );
          }
          final marker = utf8.encode('\r\n\r\n');
          bodyOffset = _indexOf(chunks, marker);
          if (bodyOffset < 0) continue;
          bodyOffset += marker.length;
          lineStart = bodyOffset;
          headerDone = true;
        }

        while (lineStart < chunks.length) {
          final nl = _indexOf(chunks, const [0x0a], from: lineStart);
          if (nl < 0) break;
          final lineBytes = chunks.sublist(lineStart, nl);
          lineStart = nl + 1;
          if (lineBytes.isEmpty ||
              (lineBytes.length == 1 && lineBytes[0] == 0x0d)) {
            continue;
          }
          final end =
              lineBytes.isNotEmpty && lineBytes.last == 0x0d
                  ? lineBytes.length - 1
                  : lineBytes.length;
          final line = utf8.decode(lineBytes.sublist(0, end)).trim();
          if (line.isEmpty) continue;
          final decoded = jsonDecode(line);
          if (decoded is! Map) continue;
          final map = Map<String, dynamic>.from(decoded);
          yield map;
          if (map['done'] == true) {
            done = true;
            break;
          }
        }
      }
      await stream.halfClose();
    } catch (e) {
      try {
        await stream.reset(reason: 1);
      } catch (_) {}
      rethrow;
    }
  }

  Future<Uint8List> httpBytes({
    required String method,
    required String path,
    String body = '',
    int maxRead = 16 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 180),
  }) async {
    final stream = await session.openStream(serviceName);
    try {
      final httpReq = _buildHttpRequest(method: method, path: path, body: body);
      await stream.write(Uint8List.fromList(utf8.encode(httpReq)));
      final chunks = <int>[];
      final deadline = DateTime.now().add(timeout);
      var emptyStreak = 0;
      while (DateTime.now().isBefore(deadline) && chunks.length < maxRead) {
        final part = await stream.read(maxLen: 65536);
        if (part.isEmpty) {
          emptyStreak++;
          if (chunks.isNotEmpty && emptyStreak >= 8) break;
          if (chunks.isEmpty && emptyStreak >= 40) break;
          await Future<void>.delayed(_poll);
          continue;
        }
        emptyStreak = 0;
        chunks.addAll(part);
        final text = utf8.decode(chunks, allowMalformed: true);
        if (_httpBodyComplete(text, null)) break;
      }
      await stream.halfClose();
      final raw = utf8.decode(chunks, allowMalformed: true);
      final status = _httpStatus(raw);
      final bodyBytes = _extractHttpBodyBytes(chunks);
      if (status != null && (status < 200 || status >= 300)) {
        throw StateError('HTTP $status: ${utf8.decode(bodyBytes, allowMalformed: true)}');
      }
      return Uint8List.fromList(bodyBytes);
    } catch (e) {
      try {
        await stream.reset(reason: 1);
      } catch (_) {}
      rethrow;
    }
  }

  static int _indexOf(List<int> haystack, List<int> needle, {int from = 0}) {
    if (needle.isEmpty) return from;
    for (var i = from; i + needle.length <= haystack.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  String _buildHttpRequest({
    required String method,
    required String path,
    required String body,
  }) {
    final bytes = utf8.encode(body);
    final buf = StringBuffer()
      ..write('$method $path HTTP/1.1\r\n')
      ..write('Host: $hostHeader\r\n')
      ..write('Connection: close\r\n');
    if (bytes.isNotEmpty) {
      buf
        ..write('Content-Type: application/json\r\n')
        ..write('Content-Length: ${bytes.length}\r\n');
    } else {
      buf.write('Content-Length: 0\r\n');
    }
    buf.write('\r\n');
    if (bytes.isNotEmpty) buf.write(body);
    return buf.toString();
  }

  static int? _httpStatus(String raw) {
    final lineEnd = raw.indexOf('\r\n');
    final line = lineEnd < 0 ? raw : raw.substring(0, lineEnd);
    final parts = line.split(' ');
    if (parts.length >= 2) return int.tryParse(parts[1]);
    return null;
  }

  static bool _httpBodyComplete(
    String raw,
    bool Function(String body)? bodyLooksComplete,
  ) {
    final sep = raw.indexOf('\r\n\r\n');
    if (sep < 0) return false;
    final headers = raw.substring(0, sep).toLowerCase();
    final body = raw.substring(sep + 4);
    final clMatch = RegExp(r'content-length:\s*(\d+)').firstMatch(headers);
    if (clMatch != null) {
      final len = int.tryParse(clMatch.group(1)!) ?? -1;
      if (len >= 0) return utf8.encode(body).length >= len;
    }
    if (bodyLooksComplete != null) return bodyLooksComplete(body);
    return false;
  }

  static String _extractHttpBody(String raw) {
    final sep = raw.indexOf('\r\n\r\n');
    if (sep < 0) return raw;
    return raw.substring(sep + 4);
  }

  static List<int> _extractHttpBodyBytes(List<int> chunks) {
    final raw = utf8.decode(chunks, allowMalformed: true);
    final sep = raw.indexOf('\r\n\r\n');
    if (sep < 0) return chunks;
    // Approximate: find sep in bytes
    final marker = utf8.encode('\r\n\r\n');
    for (var i = 0; i + marker.length <= chunks.length; i++) {
      var ok = true;
      for (var j = 0; j < marker.length; j++) {
        if (chunks[i + j] != marker[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return chunks.sublist(i + marker.length);
    }
    return utf8.encode(_extractHttpBody(raw));
  }
}
