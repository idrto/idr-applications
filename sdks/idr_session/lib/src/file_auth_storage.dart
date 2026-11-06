import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:two_key_dart_sdk/two_key_headless.dart';

import 'flavor.dart';

/// [BillingAuthStorage] as one file (CLI / headless; no Flutter).
///
/// Windows: the JSON is encrypted with DPAPI (only this Windows user can read
/// it). Elsewhere: plain JSON, mode 0600.
/// ponytail: no Keychain / libsecret on macOS / Linux yet; add a key there if
/// those builds ship to end users.
///
/// Several processes can share one file (the Target GUI and `idrt` do): every
/// read-modify-write holds an OS lock on `<file>.lock` and replaces the file
/// with a rename, so a crash never leaves it half written.
///
/// Default location: `%APPDATA%\idr.to-s\secure\auth.json` or `~/.config/idr.to-s/secure/auth.json`.
class FileAuthStorage implements BillingAuthStorage {
  FileAuthStorage({File? file}) : _file = file ?? _defaultFile();

  final File _file;

  /// The backing file (watch its folder to see other processes' writes).
  File get file => _file;

  /// File locks don't exclude callers within one process: queue them here.
  Future<void> _queue = Future<void>.value();

  static File _defaultFile() =>
      File(p.join(idrSourceDirectory.path, 'secure', 'auth.json'));

  @override
  Future<String?> getItem(String key) => _locked((m) => m[key], write: false);

  @override
  Future<void> setItem(String key, String value) =>
      _locked((m) => m[key] = value, write: true);

  @override
  Future<void> removeItem(String key) => _locked((m) => m.remove(key), write: true);

  Future<T> _locked<T>(T Function(Map<String, String> map) op, {required bool write}) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        await _file.parent.create(recursive: true);
        final lock = await File('${_file.path}.lock').open(mode: FileMode.append);
        try {
          await lock.lock(FileLock.blockingExclusive, 0, 1);
          final map = await _read();
          final result = op(map);
          if (write) await _write(map);
          done.complete(result);
        } finally {
          await lock.close();
        }
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<Map<String, String>> _read() async {
    if (!await _file.exists()) return {};
    final bytes = await _file.readAsBytes();
    if (bytes.isEmpty) return {};
    final decoded = jsonDecode(
      utf8.decode(Platform.isWindows ? _dpapi(bytes, protect: false) : bytes),
    );
    return decoded is Map ? decoded.map((k, v) => MapEntry('$k', '$v')) : {};
  }

  Future<void> _write(Map<String, String> map) async {
    final bytes = utf8.encode(jsonEncode(map));
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsBytes(
      Platform.isWindows ? _dpapi(bytes, protect: true) : bytes,
      flush: true,
    );
    if (!Platform.isWindows) await Process.run('chmod', ['600', tmp.path]);
    await tmp.rename(_file.path);
  }

  Uint8List _dpapi(Uint8List data, {required bool protect}) {
    final fn = DynamicLibrary.open('crypt32.dll')
        .lookupFunction<_CryptC, _CryptD>(protect ? 'CryptProtectData' : 'CryptUnprotectData');
    final localFree = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('LocalFree');
    return using((arena) {
      final buf = arena<Uint8>(data.length);
      buf.asTypedList(data.length).setAll(0, data);
      final input = arena<_Blob>();
      input.ref
        ..cbData = data.length
        ..pbData = buf;
      final out = arena<_Blob>();
      if (fn(input, nullptr, nullptr, nullptr, nullptr, _uiForbidden, out) == 0) {
        throw FileSystemException(
          'could not ${protect ? 'encrypt' : 'decrypt'} the auth file (DPAPI)',
          _file.path,
        );
      }
      try {
        return Uint8List.fromList(out.ref.pbData.asTypedList(out.ref.cbData));
      } finally {
        localFree(out.ref.pbData.cast());
      }
    });
  }
}

const _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN

/// DATA_BLOB.
final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

// CryptProtectData / CryptUnprotectData share this shape (the description
// argument is unused, so both pass null).
typedef _CryptC = Int32 Function(
    Pointer<_Blob>, Pointer<Void>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _CryptD = int Function(
    Pointer<_Blob>, Pointer<Void>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);
