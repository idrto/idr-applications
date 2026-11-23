import 'package:idr_telemetry/idr_telemetry.dart';

// The message pieces are shared with the CLIs.
export 'package:idr_telemetry/idr_telemetry.dart'
    show reportRecipient, maxLinkChars, maxDescriptionChars, reportSubject, reportDetails, reportBody, mailtoLink;

/// Email issue reporting (docs/observability/04 §4.2a, D15). The app only prepares a
/// bundle and a prefilled `mailto:` link; the user attaches the ZIP and sends it.
const maxZipBytes = 25 * 1024 * 1024;
const _log = IdrLog('idr_target_app.report');

class ReportResult {
  ReportResult(this.bundle, this.window, {this.reduced = false});
  final DiagnosticBundle bundle;
  final Duration window;
  final bool reduced;
  int get bytes => bundle.file.lengthSync();
}

/// Builds the bundle; if it exceeds [maxZipBytes] the window is halved (down to 15 min).
Future<ReportResult> buildReport({
  required String description,
  required Duration window,
  Map<String, Object?>? state,
  Future<DiagnosticBundle> Function(Duration window, String note, Map<String, Object?>? state) collect = _collect,
}) async {
  _log.info('diag.report.started');
  final note = redact(description.trim());
  var w = window;
  var reduced = false;
  while (true) {
    final b = await collect(w, note, state);
    final size = b.file.lengthSync();
    if (size <= maxZipBytes || w <= const Duration(minutes: 15)) {
      _log.info('diag.report.built', attrs: {'bytes': size, 'files': (b.manifest['files'] as Map?)?.length ?? 0, 'window_s': w.inSeconds});
      return ReportResult(b, w, reduced: reduced);
    }
    b.file.deleteSync();
    w = Duration(seconds: w.inSeconds ~/ 2);
    reduced = true;
  }
}

Future<DiagnosticBundle> _collect(Duration w, String note, Map<String, Object?>? state) =>
    DiagnosticBundle.collect(window: w, userNote: note, state: state);

void logMailOpened() => _log.info('diag.report.mail_opened');
void logMailLaunchFailed(String reason) => _log.warn('diag.report.mail_launch_failed', errorType: 'mail_launch_failed', attrs: {'reason': reason});
void logReportDeleted() => _log.info('diag.report.deleted');
