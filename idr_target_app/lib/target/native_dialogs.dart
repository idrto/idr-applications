import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// Native pickers (Windows `IFileOpenDialog`). Paths are only proposals: the
/// agent still checks every one (permitted directories, links) in Rust.
class NativeDialogs {
  /// Whether this platform has the native pickers.
  static bool get available => Platform.isWindows;

  /// One folder, or null when cancelled.
  static String? pickFolder({String title = 'Choose a folder'}) =>
      _pick(title: title, options: FOS_PICKFOLDERS)?.firstOrNull;

  /// One or more files, or null when cancelled.
  static List<String>? pickFiles({String title = 'Choose files'}) =>
      _pick(title: title, options: FOS_ALLOWMULTISELECT);

  /// Create the dialog, apply [options] as [_pick] does, read them back and
  /// release it, without showing anything (checks the COM wiring).
  @visibleForTesting
  static int configuredOptions(FILEOPENDIALOGOPTIONS options) {
    CoInitializeEx(COINIT_APARTMENTTHREADED);
    final dialog = createInstance<IFileOpenDialog>(FileOpenDialog);
    try {
      dialog.setOptions(FILEOPENDIALOGOPTIONS(dialog.getOptions() | options | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST));
      return dialog.getOptions();
    } finally {
      dialog.release();
    }
  }

  /// `HRESULT_FROM_WIN32(ERROR_CANCELLED)`: the user closed the dialog.
  static const _cancelled = 0x800704C7;

  static List<String>? _pick({required String title, required FILEOPENDIALOGOPTIONS options}) {
    if (!available) return null;
    // The UI thread is already a COM apartment; a repeat init is harmless.
    CoInitializeEx(COINIT_APARTMENTTHREADED);
    final dialog = createInstance<IFileOpenDialog>(FileOpenDialog);
    final titleW = title.toPcwstr();
    try {
      dialog.setOptions(FILEOPENDIALOGOPTIONS(dialog.getOptions() | options | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST));
      dialog.setTitle(titleW);
      try {
        dialog.show(null);
      } on WindowsException catch (e) {
        if ((e.hr & 0xFFFFFFFF) == _cancelled) return null;
        rethrow;
      }
      final items = dialog.getResults();
      if (items == null) return null;
      final paths = <String>[];
      for (var i = 0; i < items.getCount(); i++) {
        final item = items.getItemAt(i);
        if (item == null) continue;
        final name = item.getDisplayName(SIGDN_FILESYSPATH);
        paths.add(name.toDartString());
        CoTaskMemFree(name);
        item.release();
      }
      items.release();
      return paths.isEmpty ? null : paths;
    } finally {
      dialog.release();
      free(titleW);
    }
  }
}
