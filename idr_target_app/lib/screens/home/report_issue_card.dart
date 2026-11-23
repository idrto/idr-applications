import 'dart:io';

import 'package:flutter/services.dart';
import 'package:idr_target/idr_target.dart' show IdrFlavor;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../diagnostics/issue_report.dart';
import '../../ui/index.dart';

const _appVersion = '1.0.0+1';

/// "Report an issue": build a diagnostic ZIP, then open the user's mail program with a
/// prefilled message. Nothing is attached or sent by the app (04 §4.2a, D15).
class ReportIssueCard extends StatefulWidget {
  const ReportIssueCard({super.key, this.launch, this.build, this.reveal});

  /// Test hooks.
  final Future<bool> Function(Uri uri)? launch;
  final Future<ReportResult> Function(String description, Duration window)? build;
  final Future<void> Function(Directory dir)? reveal;

  @override
  State<ReportIssueCard> createState() => _ReportIssueCardState();
}

class _ReportIssueCardState extends State<ReportIssueCard> {
  final _text = TextEditingController();
  bool _day = false;
  bool _busy = false;
  ReportResult? _report;
  String? _body;
  String? _status;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _build() async {
    if (_text.text.trim().isEmpty) {
      setState(() => _status = 'Please describe the problem first.');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final window = _day ? const Duration(hours: 24) : const Duration(hours: 2);
      final build = widget.build ?? (d, w) => buildReport(description: d, window: w);
      final r = await build(_text.text, window);
      final id = r.bundle.reportId;
      final details = reportDetails(
        reportId: id,
        zipName: r.bundle.file.uri.pathSegments.last,
        zipBytes: r.bytes,
        appVersion: _appVersion,
        flavor: IdrFlavor.current.name,
      );
      if (!mounted) return;
      setState(() {
        _report = r;
        _body = reportBody(description: _text.text, details: details, reportId: id);
      });
    } on Object catch (e) {
      if (mounted) setState(() => _status = 'Could not build the report: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMail() async {
    final r = _report!;
    final uri = Uri.parse(mailtoLink(reportSubject(r.bundle.reportId), _body!));
    var ok = false;
    try {
      ok = await (widget.launch ?? launchUrl)(uri);
    } on Object {
      ok = false;
    }
    if (ok) {
      logMailOpened();
    } else {
      logMailLaunchFailed('launch_failed');
    }
    if (!mounted) return;
    setState(() {
      _status = ok
          ? 'Your email program was opened. Attach the ZIP file, then send the email.'
          : 'No email program was found. Use the buttons below to copy the details.';
    });
    await _reveal();
  }

  Future<void> _reveal() async {
    final dir = _report!.bundle.file.parent;
    try {
      final reveal = widget.reveal ?? (Directory d) async {
        await launchUrl(Uri.file(d.path));
      };
      await reveal(dir);
    } on Object {
      // "Copy ZIP path" remains available.
    }
  }

  void _copy(String what, String text) {
    Clipboard.setData(ClipboardData(text: text));
    setState(() => _status = '$what copied.');
  }

  void _delete() {
    try {
      _report?.bundle.file.deleteSync();
    } on Object {
      // already gone
    }
    logReportDeleted();
    setState(() {
      _report = null;
      _body = null;
      _status = 'Report deleted.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return IdrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Report an issue', style: IdrText.body(weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            'Describe the problem. IDR builds a diagnostic ZIP on this computer and opens your '
            'email program. Nothing is sent automatically: you attach the ZIP and press Send. '
            'Do not include passwords or tokens.',
            style: IdrText.body(color: IdrColors.zinc500),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('report_description'),
            controller: _text,
            maxLines: 5,
            maxLength: maxDescriptionChars,
            decoration: const InputDecoration(hintText: 'What happened? What did you expect?'),
          ),
          Row(
            children: [
              Checkbox(value: _day, onChanged: _busy ? null : (v) => setState(() => _day = v ?? false)),
              const Text('Include the last 24 hours (default: 2 hours)'),
            ],
          ),
          const SizedBox(height: 8),
          IdrButton(
            label: r == null ? 'Create report' : 'Create again',
            variant: IdrButtonVariant.primary,
            size: IdrButtonSize.sm,
            loading: _busy,
            onPressed: _busy ? null : _build,
          ),
          if (r != null) ..._result(r),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_status!, key: const Key('report_status')),
            ),
        ],
      ),
    );
  }

  List<Widget> _result(ReportResult r) {
    final id = r.bundle.reportId;
    final span = r.window.inHours >= 1 ? '${r.window.inHours} h' : '${r.window.inMinutes} min';
    return [
      const SizedBox(height: 12),
      Text(
        'Report $id\n${(r.bytes / 1024).round()} KiB, last $span'
        '${r.reduced ? ' (shortened to fit the 25 MiB email limit)' : ''}\n'
        'Contains your description, the app and agent logs for that time, crash records and '
        'the app state summary. Sensitive values are removed.',
        style: IdrText.mono(size: 11, color: IdrColors.zinc500),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        IdrButton(label: 'Open email', variant: IdrButtonVariant.primary, size: IdrButtonSize.sm, onPressed: _openMail),
        IdrButton(label: 'Show in folder', size: IdrButtonSize.sm, onPressed: _reveal),
        IdrButton(label: 'Delete report', variant: IdrButtonVariant.ghost, size: IdrButtonSize.sm, onPressed: _delete),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        IdrButton(label: 'Copy email address', size: IdrButtonSize.xs, onPressed: () => _copy('Email address', reportRecipient)),
        IdrButton(label: 'Copy subject', size: IdrButtonSize.xs, onPressed: () => _copy('Subject', reportSubject(id))),
        IdrButton(label: 'Copy message', size: IdrButtonSize.xs, onPressed: () => _copy('Message', _body!)),
        IdrButton(label: 'Copy ZIP path', size: IdrButtonSize.xs, onPressed: () => _copy('Path', r.bundle.file.path)),
      ]),
    ];
  }
}
