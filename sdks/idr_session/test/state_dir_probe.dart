import 'dart:io';

import 'package:idr_session/idr_session.dart';

/// Run by state_dir_test.dart with a temp APPDATA/HOME: prints the folder.
void main() => stdout.write(idrStateDirectory('idr.to-t',
    legacy: ['$idrStateBase${Platform.pathSeparator}old']).path);
