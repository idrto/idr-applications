/// Minimal usage sketch (not a runnable Flutter app).
///
/// ```sh
/// dart run example/main.dart
/// ```
library;

import 'package:idr_target/idr_target.dart';

Future<void> main() async {
  final target = IdrTarget(
    config: IdrTargetConfig(
      controlPlaneUrl: Uri.parse('http://127.0.0.1:3000'),
      agentBinaryPath: 'target-agent',
      mode: IdrTargetMode.development,
    ),
  );

  target.statusStream.listen((s) => print('status: $s'));
  target.attentionStream.listen((a) {
    if (a != null) print('attention: ${a.code} — ${a.message}');
  });

  await target.start();
  print('initial status: ${target.status}');
  await target.dispose();
}
