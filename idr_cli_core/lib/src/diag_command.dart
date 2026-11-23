import 'package:args/command_runner.dart';
import 'package:idr_telemetry/idr_telemetry.dart';

import '../idr_cli_core.dart';

/// `<cli> diag report`: builds the diagnostic ZIP (docs/observability/04 §4.2) and prints where
/// it is, its `report_id`, and the support email details to paste. Nothing is sent: a CLI
/// cannot reliably open a mail program, so the user writes the email and attaches the ZIP.
class DiagCommand extends Command<int> {
  DiagCommand({required this.program, required this.version}) {
    addSubcommand(_ReportCommand(program, version));
  }

  final String program;
  final String version;

  @override
  String get name => 'diag';

  @override
  String get description => 'Diagnostics: build a report to send to support.';
}

class _ReportCommand extends Command<int> {
  _ReportCommand(this.program, this.version) {
    argParser
      ..addOption('window', defaultsTo: '2h', help: 'How far back to include: 15m, 2h, 24h.')
      ..addOption('note', help: 'What went wrong (included in the report).')
      ..addOption('out', help: 'Copy the ZIP to this path.');
  }

  final String program;
  final String version;

  @override
  String get name => 'report';

  @override
  String get description => 'Build a diagnostic ZIP and print the email details to send it with.';

  @override
  Future<int> run() async {
    final window = parseWindow('${argResults!['window']}');
    if (window == null) {
      throw const CliError(CliExit.usage, 'Unknown --window.', hint: 'Use e.g. 15m, 2h or 24h.', code: 'USAGE');
    }
    final note = (argResults!['note'] as String?)?.trim() ?? '';
    if (Telemetry.instance == null) {
      throw const CliError(CliExit.config, 'Logging is not available, so there is nothing to report.',
          hint: 'Check that the log folder is writable (IDR_LOG_DIR).', code: 'NO_LOGS');
    }
    final bundle = await ui.task('Building report', () => DiagnosticBundle.collect(window: window, userNote: note));
    var path = bundle.file.path;
    final out = argResults!['out'] as String?;
    if (out != null && out.isNotEmpty) {
      bundle.file.copySync(out);
      path = out;
    }
    final size = bundle.file.lengthSync();
    final id = bundle.reportId;
    final details = reportDetails(
      reportId: id,
      zipName: '$id.zip',
      zipBytes: size,
      appVersion: '$program $version',
      flavor: 'cli',
    );
    final body = reportBody(description: note.isEmpty ? '(describe the problem here)' : note, details: details, reportId: id);
    final data = {
      'report_id': id,
      'file': path,
      'bytes': size,
      'window_s': window.inSeconds,
      'email': {'to': reportRecipient, 'subject': reportSubject(id), 'body': body},
    };
    ui.result(data, human: () {
      ui.success('Report ready: $path (${(size / 1024).round()} KiB)');
      ui.info('');
      ui.info('Send it by email. Nothing was sent automatically.');
      ui.fields({'To': reportRecipient, 'Subject': reportSubject(id)});
      ui.info('');
      ui.info(body);
      ui.hint('Attach the ZIP file above, then send the email.');
    });
    return CliExit.ok;
  }
}

/// `15m`, `2h`, `24h` → a Duration; null when it is none of those (max 7 days).
Duration? parseWindow(String s) {
  final m = RegExp(r'^(\d{1,3})([mh])$').firstMatch(s.trim());
  if (m == null) return null;
  final n = int.parse(m[1]!);
  final d = m[2] == 'm' ? Duration(minutes: n) : Duration(hours: n);
  return n == 0 || d > const Duration(days: 7) ? null : d;
}
