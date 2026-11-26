import 'package:material_ui/material_ui.dart';
import 'package:idr_target/idr_target.dart';

import 'package:flutter/services.dart';

import '../../target/target_controller.dart';
import '../../ui/index.dart';
import '../../widgets/common.dart';

class ServicesSection extends StatefulWidget {
  const ServicesSection({super.key, required this.controller});

  final TargetController controller;

  @override
  State<ServicesSection> createState() => _ServicesSectionState();
}

class _ServicesSectionState extends State<ServicesSection> {
  TargetController get controller => widget.controller;

  /// Verified custom domains (browser addresses) and the private-access key.
  List<String> _webDomains = const [];
  String? _accessKey;

  @override
  void initState() {
    super.initState();
    _loadWeb();
  }

  Future<void> _loadWeb() async {
    final domains = await controller.domains() ?? const [];
    final key = await controller.target.webAccessKey();
    if (!mounted) return;
    setState(() {
      _webDomains = [
        for (final d in domains)
          if (d.verified) d.domain,
      ];
      _accessKey = key;
    });
  }

  /// Browser link for [s]; private links carry the key once (it becomes a cookie).
  String? _link(IdrServiceEntry s) {
    if (_webDomains.isEmpty || s.webPath == null) return null;
    final path = s.webPath == '/' ? '/' : '${s.webPath}/';
    final base = 'https://${_webDomains.first}$path';
    return s.webAccess == 'private' && _accessKey != null
        ? '$base?idr_key=$_accessKey'
        : base;
  }

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
        if (services.any((s) => s.onWeb)) _browserCard(c),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
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
                                IdrTag(
                                  label: s.type.toUpperCase(),
                                  caps: false,
                                ),
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
                        onChanged: c.busy
                            ? null
                            : (_) => c.toggleService(s.name),
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
                  if (s.type == 'http') ...[
                    const SizedBox(height: 10),
                    _webRow(context, s),
                  ],
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

  /// Address, access key and certificate state for browser access.
  Widget _browserCard(TargetController c) {
    final staging = _webDomains.any(
      (d) => c.target.acmeStatus(d)?.staging ?? false,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: IdrCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Browser access', style: IdrText.display(size: 14)),
            const SizedBox(height: 4),
            Text(
              'Public services open for anyone with the link. Private services ask for the access key; copied private links include it.',
              style: IdrText.body(size: 12, color: IdrColors.zinc500),
            ),
            const SizedBox(height: 12),
            if (_webDomains.isEmpty)
              const IdrAlert(
                tone: IdrTone.warning,
                title: 'No verified custom domain yet',
                message: 'Add one under Domains to get a browser address.',
              )
            else
              for (final d in _webDomains)
                CopyValue(value: 'https://$d', label: 'Address'),
            if (_accessKey != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    'Access key  ',
                    style: IdrText.body(size: 12, color: IdrColors.zinc500),
                  ),
                  Flexible(
                    child: CopyValue(value: _accessKey!, label: 'Access key'),
                  ),
                ],
              ),
            ],
            if (staging) ...[
              const SizedBox(height: 12),
              const IdrAlert(
                tone: IdrTone.warning,
                title: 'Test certificate',
                message: 'The certificate is from Let\'s Encrypt staging, so browsers show a warning until a production certificate is issued.',
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Off / Private / Public, the path, and Copy link for one HTTP service.
  Widget _webRow(BuildContext context, IdrServiceEntry s) {
    final c = controller;
    final mode = s.webPath == null ? 'off' : s.webAccess;
    final link = _link(s);
    return Row(
      children: [
        const Icon(Icons.public, size: 16, color: IdrColors.zinc400),
        const SizedBox(width: 8),
        Text(
          'Browser',
          style: IdrText.body(size: 12, color: IdrColors.zinc500),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 150,
          child: IdrSelect<String>(
            value: mode,
            options: const [
              IdrOption(value: 'off', label: 'Off'),
              IdrOption(value: 'private', label: 'Private (key)'),
              IdrOption(value: 'public', label: 'Public'),
            ],
            onChanged: c.busy
                ? null
                : (v) => _setWeb(
                    context,
                    s,
                    path: v == 'off' ? null : (s.webPath ?? '/${s.name}'),
                    access: v == 'off' ? s.webAccess : v,
                  ),
          ),
        ),
        if (s.webPath != null) ...[
          const SizedBox(width: 12),
          Text(s.webPath!, style: IdrText.mono(size: 12)),
          IconButton(
            tooltip: 'Change path',
            onPressed: c.busy ? null : () => _editPath(context, s),
            icon: const Icon(
              Icons.edit_outlined,
              size: 16,
              color: IdrColors.zinc400,
            ),
          ),
        ],
        const Spacer(),
        if (link != null)
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Link copied'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
            icon: const Icon(Icons.link, size: 16),
            label: Text(
              s.webAccess == 'private' ? 'Copy private link' : 'Copy link',
            ),
          ),
      ],
    );
  }

  Future<void> _setWeb(
    BuildContext context,
    IdrServiceEntry s, {
    String? path,
    required String access,
  }) async {
    final err = await controller.setServiceWeb(
      s.name,
      path: path,
      access: access,
    );
    if (err != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _editPath(BuildContext context, IdrServiceEntry s) async {
    final field = TextEditingController(text: s.webPath);
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Browser path for ${s.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IdrTextField(controller: field, mono: true, hint: '/${s.name}'),
            const SizedBox(height: 8),
            Text(
              'Use / for a website (it gets every path no other service uses), or /name for an app or API.',
              style: IdrText.body(size: 12, color: IdrColors.zinc500),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, field.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    if (path != null && context.mounted) {
      await _setWeb(context, s, path: path, access: s.webAccess);
    }
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
