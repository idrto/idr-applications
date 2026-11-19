import 'dart:convert';
import 'dart:io';

import 'package:idr_session/idr_session.dart';

/// Run by state_dir_test.dart with a temp APPDATA/HOME: prints both paths.
void main(List<String> args) {
  IdrFlavor.current = IdrFlavor(name: args.single);
  stdout.write(jsonEncode({
    'source': idrSourceDirectory.path,
    'target': idrStateDirectory('target').path,
  }));
}
