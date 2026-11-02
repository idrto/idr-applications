import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Why a request to the agent didn't get an answer.
class AgentIpcException implements Exception {
  const AgentIpcException(this.kind, [this.detail = '']);

  /// `agent_not_running`, `agent_untrusted` (the endpoint belongs to another
  /// user) or `agent_failed`.
  final String kind;
  final String detail;

  @override
  String toString() => 'AgentIpcException($kind) $detail';
}

/// A persistent connection to a running agent's local IPC (the same endpoint
/// its CLI uses): a named pipe on Windows, a Unix socket elsewhere. One JSON
/// request line, one JSON response line, many per connection. Requests are
/// sent one at a time; a broken connection (agent restarted) is reopened once.
class AgentIpc {
  AgentIpc({required this.agent, required this.dataDir});

  /// `target-agent` or `source-agent`.
  final String agent;

  /// The agent's transfer data dir (holds the Unix socket).
  final String dataDir;

  _Conn? _conn;
  Future<void> _queue = Future.value();

  /// Send [request] (e.g. `{'cmd': 'list'}`) and return the agent's response.
  Future<Map<String, dynamic>> call(Map<String, Object?> request) {
    final line = jsonEncode(request);
    final done = Completer<Map<String, dynamic>>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await _roundTrip(line));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<Map<String, dynamic>> _roundTrip(String line) async {
    for (var attempt = 0;; attempt++) {
      _conn ??= Platform.isWindows ? await _PipeConn.open(agent) : await _SocketConn.open(agent, dataDir);
      try {
        final reply = await _conn!.exchange(line);
        return Map<String, dynamic>.from(jsonDecode(reply) as Map);
      } on _Broken {
        await close();
        if (attempt > 0) rethrow;
      }
    }
  }

  /// Close the connection (it reopens on the next call).
  Future<void> close() async {
    final c = _conn;
    _conn = null;
    await c?.close();
  }
}

class _Broken implements Exception {
  const _Broken();
}

abstract class _Conn {
  Future<String> exchange(String line);
  Future<void> close();
}

// ---- Unix socket -----------------------------------------------------------------

class _SocketConn implements _Conn {
  _SocketConn(this._socket) {
    _socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
          (l) => _lines.add(l),
          onDone: () => _lines.close(),
          onError: (_) => _lines.close(),
        );
    _it = StreamIterator(_lines.stream);
  }

  final Socket _socket;
  final _lines = StreamController<String>();
  late final StreamIterator<String> _it;

  static Future<_SocketConn> open(String agent, String dataDir) async {
    final path = '$dataDir${Platform.pathSeparator}ipc${Platform.pathSeparator}$agent.sock';
    try {
      // The socket lives in a 0700 directory of this user: only this user's agent can create it.
      return _SocketConn(await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0));
    } on SocketException {
      throw const AgentIpcException('agent_not_running');
    }
  }

  @override
  Future<String> exchange(String line) async {
    try {
      _socket.write('$line\n');
      await _socket.flush();
    } on SocketException {
      throw const _Broken();
    }
    if (!await _it.moveNext()) throw const _Broken();
    return _it.current;
  }

  @override
  Future<void> close() async {
    await _socket.close();
    await _it.cancel();
  }
}

// ---- Windows named pipe (blocking I/O on a worker isolate) --------------------------

class _PipeConn implements _Conn {
  _PipeConn(this._isolate, this._commands, this._replies, this._it);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _replies;

  /// The worker's messages in order: its command port, then 'ok' (or why
  /// not), then one reply per command.
  final StreamIterator<dynamic> _it;

  static Future<_PipeConn> open(String agent) async {
    final replies = ReceivePort();
    final it = StreamIterator<dynamic>(replies);
    final isolate = await Isolate.spawn(_pipeWorker, [replies.sendPort, agent], debugName: 'idr_agent_ipc');
    if (!await it.moveNext() || it.current is! SendPort) {
      replies.close();
      throw const AgentIpcException('agent_failed', 'IPC worker did not start');
    }
    final conn = _PipeConn(isolate, it.current as SendPort, replies, it);
    final opened = await conn._next();
    if (opened != 'ok') {
      await conn.close();
      throw AgentIpcException(opened as String);
    }
    return conn;
  }

  Future<dynamic> _next() async => await _it.moveNext() ? _it.current : '_broken';

  @override
  Future<String> exchange(String line) async {
    _commands.send(line);
    final r = await _next();
    if (r is String && r.startsWith('{')) return r;
    throw const _Broken();
  }

  @override
  Future<void> close() async {
    _commands.send(null);
    await _it.cancel();
    _replies.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

const _genericRead = 0x80000000;
const _genericWrite = 0x40000000;
const _openExisting = 3;
const _tokenQuery = 0x0008;
const _tokenUser = 1;
const _processQueryLimited = 0x1000;

typedef _CreateFileC = IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _CreateFileD = int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _RwC = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _RwD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);

/// Win32 calls the pipe client needs (kernel32 / advapi32, no extra package).
class _Win {
  _Win()
      : _k = DynamicLibrary.open('kernel32.dll'),
        _a = DynamicLibrary.open('advapi32.dll');

  final DynamicLibrary _k;
  final DynamicLibrary _a;

  late final createFile = _k.lookupFunction<_CreateFileC, _CreateFileD>('CreateFileW');
  late final readFile = _k.lookupFunction<_RwC, _RwD>('ReadFile');
  late final writeFile = _k.lookupFunction<_RwC, _RwD>('WriteFile');
  late final closeHandle = _k.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  late final waitNamedPipe =
      _k.lookupFunction<Int32 Function(Pointer<Utf16>, Uint32), int Function(Pointer<Utf16>, int)>('WaitNamedPipeW');
  late final serverPid = _k.lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
      'GetNamedPipeServerProcessId');
  late final currentProcess = _k.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  late final openProcess =
      _k.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>('OpenProcess');
  late final localFree = _k.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('LocalFree');
  late final openProcessToken = _a.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
      int Function(int, int, Pointer<IntPtr>)>('OpenProcessToken');
  late final getTokenInformation = _a.lookupFunction<Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
      int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)>('GetTokenInformation');
  late final sidToString = _a.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>),
      int Function(Pointer<Void>, Pointer<Pointer<Utf16>>)>('ConvertSidToStringSidW');

  /// The user SID `process` runs as (`S-1-5-21-…`), or null.
  String? processSid(int process) => using((arena) {
        final token = arena<IntPtr>();
        if (openProcessToken(process, _tokenQuery, token) == 0) return null;
        try {
          final len = arena<Uint32>();
          getTokenInformation(token.value, _tokenUser, nullptr, 0, len);
          if (len.value == 0) return null;
          final buf = arena<Uint8>(len.value);
          if (getTokenInformation(token.value, _tokenUser, buf.cast(), len.value, len) == 0) return null;
          // TOKEN_USER starts with SID_AND_ATTRIBUTES { PSID Sid; DWORD Attributes; }.
          final sid = buf.cast<Pointer<Void>>().value;
          final str = arena<Pointer<Utf16>>();
          if (sidToString(sid, str) == 0) return null;
          final s = str.value.toDartString();
          localFree(str.value.cast());
          return s;
        } finally {
          closeHandle(token.value);
        }
      });

  /// Whether the pipe's server process runs as [sid].
  bool serverIs(int pipe, String sid) => using((arena) {
        final pid = arena<Uint32>();
        if (serverPid(pipe, pid) == 0) return false;
        final process = openProcess(_processQueryLimited, 0, pid.value);
        if (process == 0) return false;
        try {
          return processSid(process) == sid;
        } finally {
          closeHandle(process);
        }
      });
}

/// Worker: opens and owns the pipe; each command line → one response line.
void _pipeWorker(List<Object?> args) {
  final replies = args[0]! as SendPort;
  final agent = args[1]! as String;
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  final win = _Win();
  final sid = win.processSid(win.currentProcess());
  if (sid == null) {
    replies.send('agent_failed');
    return;
  }
  final name = '\\\\.\\pipe\\idr-$agent-$sid'.toNativeUtf16();
  var handle = win.createFile(name, _genericRead | _genericWrite, 0, nullptr, _openExisting, 0, 0);
  // All instances busy: wait for one (the agent serves each connection on its own task).
  if (handle == -1 && win.waitNamedPipe(name, 2000) != 0) {
    handle = win.createFile(name, _genericRead | _genericWrite, 0, nullptr, _openExisting, 0, 0);
  }
  calloc.free(name);
  if (handle == -1) {
    replies.send('agent_not_running');
    return;
  }
  // Another account could have created this pipe name first.
  if (!win.serverIs(handle, sid)) {
    win.closeHandle(handle);
    replies.send('agent_untrusted');
    return;
  }
  replies.send('ok');
  const chunk = 64 * 1024;
  final buf = calloc<Uint8>(chunk);
  final n = calloc<Uint32>();
  final pending = BytesBuilder(copy: false);
  commands.listen((msg) {
    if (msg == null) {
      win.closeHandle(handle);
      calloc.free(buf);
      calloc.free(n);
      commands.close();
      return;
    }
    final out = utf8.encode('$msg\n');
    final p = calloc<Uint8>(out.length);
    p.asTypedList(out.length).setAll(0, out);
    final wrote = win.writeFile(handle, p, out.length, n, nullptr) != 0 && n.value == out.length;
    calloc.free(p);
    if (!wrote) {
      replies.send('_broken');
      return;
    }
    while (true) {
      if (win.readFile(handle, buf, chunk, n, nullptr) == 0 || n.value == 0) {
        replies.send('_broken');
        return;
      }
      pending.add(buf.asTypedList(n.value).toList());
      final bytes = pending.takeBytes();
      final nl = bytes.indexOf(10);
      if (nl >= 0) {
        replies.send(utf8.decode(bytes.sublist(0, nl)));
        if (nl + 1 < bytes.length) pending.add(bytes.sublist(nl + 1));
        return;
      }
      pending.add(bytes);
    }
  });
}
