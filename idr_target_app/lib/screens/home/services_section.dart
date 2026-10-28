import 'package:flutter/material.dart';
import 'package:idr_target/idr_target.dart';

import '../../target/target_controller.dart';
import '../../ui/components/buttons/idr_button.dart';
import '../../ui/components/cards/idr_card.dart';
import '../../ui/components/dialogs/idr_dialog.dart';
import '../../ui/components/feedback/idr_feedback.dart';
import '../../ui/components/inputs/idr_fields.dart';
import '../../ui/components/layout/idr_layout.dart';
import '../../ui/idr/idr_service.dart';
import '../../ui/theme/idr_theme.dart';

class ServicesSection extends StatelessWidget {
  const ServicesSection({super.key, required this.controller});

  final TargetController controller;

  IdrServiceKind _kind(IdrServiceEntry s) {
    final n = '${s.name} ${s.label ?? ''}'.toLowerCase();
    if (n.contains('ollama') || n.contains('lmstudio') || n.contains('llama')) {
      return IdrServiceKind.model;
    }
    return s.type == 'tcp' ? IdrServiceKind.database : IdrServiceKind.http;
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final services = c.state.services;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IdrPageHeader(
          title: 'Services',
          subtitle: 'Local apps this machine publishes to approved Sources',
          actions: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IdrButton(
                label: 'Scan this machine',
                icon: Icons.radar,
                size: IdrButtonSize.sm,
                onPressed: c.busy ? null : () => _scan(context),
              ),
              const SizedBox(width: 8),
              IdrButton(
                label: 'Add service',
                icon: Icons.add,
                variant: IdrButtonVariant.primary,
                size: IdrButtonSize.sm,
                onPressed: c.busy ? null : () => _add(context),
              ),
            ],
          ),
        ),
        if (services.isEmpty)
          IdrCard(
            child: IdrEmpty(
              icon: Icons.dns_outlined,
              title: 'No services yet',
              description: 'Add a local app such as Ollama (http://127.0.0.1:11434). Nothing is reachable until a service is published.',
              action: IdrButton(
                label: 'Scan this machine',
                variant: IdrButtonVariant.primary,
                size: IdrButtonSize.sm,
                onPressed: c.busy ? null : () => _scan(context),
              ),
            ),
          ),
        for (final s in services)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: IdrCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  IdrServiceIcon(kind: _kind(s), size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(s.name, style: IdrText.display(size: 14)),
                            const SizedBox(width: 8),
                            IdrChip(label: s.type.toUpperCase()),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.endpoint,
                          style: IdrText.mono(
                            size: 11,
                            color: IdrColors.zinc500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    s.enabled ? 'Published' : 'Paused',
                    style: IdrText.body(size: 12, color: IdrColors.zinc500),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: s.enabled,
                    onChanged: c.busy ? null : (_) => c.toggleService(s.name),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    onPressed: c.busy ? null : () => _remove(context, s),
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: IdrColors.zinc400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (services.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              c.agentRunning
                  ? 'Changes apply to the running agent.'
                  : 'Changes publish the next time you start serving.',
              style: IdrText.body(size: 12, color: IdrColors.zinc400),
            ),
          ),
      ],
    );
  }

  Future<void> _remove(BuildContext context, IdrServiceEntry s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${s.name}?'),
        content: const Text(
          'Sources can no longer reach it through this machine.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.removeService(s.name);
  }

  Future<void> _add(BuildContext context) => showIdrDialog<void>(
    context: context,
    title: 'Add service',
    content: _AddServiceForm(controller: controller),
  );

  Future<void> _scan(BuildContext context) => showIdrDialog<void>(
    context: context,
    title: 'Scan this machine',
    content: _ScanList(controller: controller),
  );
}

class _AddServiceForm extends StatefulWidget {
  const _AddServiceForm({required this.controller});

  final TargetController controller;

  @override
  State<_AddServiceForm> createState() => _AddServiceFormState();
}

class _AddServiceFormState extends State<_AddServiceForm> {
  final _name = TextEditingController();
  final _endpoint = TextEditingController();
  String _type = 'http';
  bool _tls = false;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await widget.controller.addService(
      name: _name.text,
      type: _type,
      endpoint: _endpoint.text,
      requireTls: _tls,
    );
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IdrField(
          label: 'Service name',
          required: true,
          hint: 'What access policies allow, e.g. ollama or lmstudio.',
          child: IdrTextField(controller: _name, hint: 'ollama'),
        ),
        const SizedBox(height: 12),
        IdrField(
          label: 'Type',
          child: IdrSelect<String>(
            value: _type,
            options: const [
              IdrOption(value: 'http', label: 'HTTP'),
              IdrOption(value: 'tcp', label: 'TCP'),
            ],
            onChanged: (v) => setState(() => _type = v),
          ),
        ),
        const SizedBox(height: 12),
        IdrField(
          label: 'Local endpoint',
          required: true,
          hint: _type == 'tcp'
              ? 'host:port, e.g. 127.0.0.1:5432'
              : 'e.g. http://127.0.0.1:11434',
          child: IdrTextField(
            controller: _endpoint,
            mono: true,
            hint: _type == 'tcp' ? '127.0.0.1:5432' : 'http://127.0.0.1:11434',
          ),
        ),
        if (_type == 'http')
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            value: _tls,
            onChanged: (v) => setState(() => _tls = v ?? false),
            title: Text(
              'Require TLS to the service',
              style: IdrText.body(size: 12),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          IdrAlert(tone: IdrTone.error, title: _error!),
        ],
        const SizedBox(height: 16),
        IdrButton(
          label: 'Add service',
          variant: IdrButtonVariant.primary,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

class _ScanList extends StatefulWidget {
  const _ScanList({required this.controller});

  final TargetController controller;

  @override
  State<_ScanList> createState() => _ScanListState();
}

class _ScanListState extends State<_ScanList> {
  List<ScanHit>? _hits;
  final _picked = <ScanHit>{};
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.controller.target
        .scanExposableServices()
        .then((h) {
          if (mounted) setState(() => _hits = h);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = describeError(e));
        });
  }

  Future<void> _expose() async {
    setState(() => _saving = true);
    try {
      await widget.controller.target.exposeScanHits(_picked);
      widget.controller.refresh();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return IdrAlert(tone: IdrTone.error, title: _error!);
    final hits = _hits;
    if (hits == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (hits.isEmpty) {
      return const IdrEmpty(
        icon: Icons.radar,
        title: 'Nothing new found',
        description: 'No known app is listening on this machine that is not published yet. Add one by hand.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Select what to publish:',
          style: IdrText.body(size: 12, color: IdrColors.zinc500),
        ),
        const SizedBox(height: 8),
        for (final h in hits)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            value: _picked.contains(h),
            onChanged: (v) =>
                setState(() => v == true ? _picked.add(h) : _picked.remove(h)),
            title: Text(h.displayLabel, style: IdrText.body()),
          ),
        const SizedBox(height: 12),
        IdrButton(
          label: 'Publish ${_picked.length} service(s)',
          variant: IdrButtonVariant.primary,
          loading: _saving,
          onPressed: _picked.isEmpty || _saving ? null : _expose,
        ),
      ],
    );
  }
}
