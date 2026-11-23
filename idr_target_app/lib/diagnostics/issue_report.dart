import 'dart:io';

import 'package:idr_telemetry/idr_telemetry.dart';

/// Email issue reporting (docs/observability/04 §4.2a, D15). The app only prepares a
/// bundle and a prefilled `mailto:` link; the user attaches the ZIP and sends it.
const reportRecipient = 'dev10@advcomm.ca';
const maxLinkChars = 1800;
const maxZipBytes = 25 * 1024 * 1024;
const maxDescriptionChars = 2000;
const _log = IdrLog('idr_target_app.report');

String reportSubject(String reportId) => 'IDR issue report $reportId';

/// Fixed block under the user's text: public-class values only (04 §5.1).
String reportDetails({
  required String reportId,
  required String zipName,
  required int zipBytes,
  required String appVersion,
  required String flavor,
}) =>
    'App: $appVersion ($flavor)\n'
    'OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n'
    'Report ID: $reportId\n'
    'Attachment: $zipName (${(zipBytes / 1024).round()} KiB)\n\n'
    'Please attach the ZIP file named above.';

/// The plain-text message the user can also copy: description (redacted, truncated to fit
/// the link) + details. The full description stays in the bundle manifest.
String reportBody({required String description, required String details, required String reportId}) {
  final text = redact(description.trim());
  String compose(String t) => '$t\n\n---\n$details';
  var body = compose(text);
  var link = mailtoLink(reportSubject(reportId), body);
  if (link.length <= maxLinkChars) return body;
  const note = '… (truncated; full text in the ZIP)';
  var keep = text.length;
  while (keep > 0 && link.length > maxLinkChars) {
    keep = keep > 200 ? keep - 100 : keep - 10;
    if (keep < 0) keep = 0;
    body = compose('${text.substring(0, keep)}$note');
    link = mailtoLink(reportSubject(reportId), body);
  }
  return body;
}

/// `mailto:` with %20-encoded spaces (some clients show `+` literally).
String mailtoLink(String subject, String body) =>
    'mailto:$reportRecipient?subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(body)}';

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
