import 'package:flutter/material.dart';
import 'package:idr_target/idr_target.dart';

import '../../target/target_controller.dart';
import '../../ui/components/buttons/idr_button.dart';
import '../../ui/components/cards/idr_card.dart';
import '../../ui/components/dialogs/idr_dialog.dart';
import '../../ui/components/feedback/idr_feedback.dart';
import '../../ui/components/inputs/idr_fields.dart';
import '../../ui/components/layout/idr_layout.dart';
import '../../ui/theme/idr_theme.dart';

/// What a pending request is, in words (same wording as `idrt pending`).
String requestLabel(EnrollmentRequest r) => switch (r.kind) {
  'zone_authority' => 'Zone key for ${r.zone}',
  'machine_source' =>
    'Source ${r.verifiedFqhn ?? r.hostLabel}${r.target == null ? '' : ' for ${r.target}'}',
  _ => 'Target ${r.verifiedFqhn ?? r.hostLabel}',
};

/// Pending enrollments an admin machine reviews (`idrt <mode> pending|approve|reject`).
class ApprovalsSection extends StatefulWidget {
  const ApprovalsSection({super.key, required this.controller, this.onChanged});

  final TargetController controller;
  final VoidCallback? onChanged;

  @override
  State<ApprovalsSection> createState() => _ApprovalsSectionState();
}

class _ApprovalsSectionState extends State<ApprovalsSection> {
  List<EnrollmentRequest>? _pending;
  Set<String> _keys = const {};
  String? _loadError;
  bool _loading = false;

  TargetController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final p = await c.pendingRequests();
      final k = await c.zoneKeysHere();
      if (mounted) {
        setState(() {
          _pending = p;
          _keys = k;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadError = describeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _review(EnrollmentRequest r) async {
    final enterprise = c.plan == IdrBusinessPlan.enterprise;
    String zone = '';
    final decision = await showIdrDialog<String>(
      context: context,
      title: 'Review request',
      content: StatefulBuilder(
        builder: (ctx, setLocal) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IdrInfoGroup(
              rows: [
                IdrInfoRow(label: 'Request', value: Text(requestLabel(r))),
                IdrInfoRow(
                  label: 'Requested by',
                  value: Text(
                    r.requesterEmail.isEmpty ? '-' : r.requesterEmail,
                  ),
                ),
                IdrInfoRow(label: 'Zone', value: Text(r.zone ?? '(root)')),
                IdrInfoRow(
                  label: 'Submitted',
                  value: Text('${r.submittedAt.toLocal()}'.split('.').first),
                ),
                if (r.subjectSki != null)
                  IdrInfoRow(
                    label: 'Key SKI',
                    value: Text(r.subjectSki!),
                    mono: true,
                  ),
              ],
            ),
            if (enterprise &&
                r.zone == null &&
                !r.isZoneKey &&
                _keys.isNotEmpty) ...[
              const SizedBox(height: 12),
              IdrField(
                label: 'Sign under zone',
                child: IdrSelect<String>(
                  value: zone,
                  options: [
                    const IdrOption(
                      value: '',
                      label: 'No zone (directly under the root)',
                    ),
                    for (final z in _keys) IdrOption(value: z, label: z),
                  ],
                  onChanged: (v) => setLocal(() => zone = v),
                ),
              ),
            ],
            const SizedBox(height: 12),
            const IdrAlert(
              tone: IdrTone.warning,
              title: 'Only approve machines you recognise',
              message: 'Approving signs a certificate and takes one seat.',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: IdrButton(
                    label: 'Reject',
                    variant: IdrButtonVariant.destructive,
                    onPressed: () => Navigator.of(ctx).pop('reject'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: IdrButton(
                    label: 'Approve',
                    variant: IdrButtonVariant.primary,
                    onPressed: () => Navigator.of(ctx).pop('approve'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (decision == 'approve') {
      await c.approve(r, zone: zone.isEmpty ? null : zone);
    } else if (decision == 'reject') {
      await c.reject(r);
    } else {
      return;
    }
    await _load();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    final reg = c.registration;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IdrPageHeader(
          title: 'Approvals',
          subtitle: 'Machines and Sources waiting for your approval',
          actions: IdrButton(
            label: 'Refresh',
            icon: Icons.refresh,
            size: IdrButtonSize.sm,
            loading: _loading,
            onPressed: _loading ? null : _load,
          ),
        ),
        if (_loadError != null)
          IdrAlert(
            tone: IdrTone.error,
            title: 'Could not load requests',
            message: _loadError,
          ),
        if (pending != null && pending.isEmpty)
          IdrCard(
            child: IdrEmpty(
              icon: Icons.verified_user_outlined,
              title: 'No pending requests',
              description: reg == null
                  ? 'Nobody can enroll yet. Register this machine as a Target first.'
                  : 'People appear here after they run: idr enroll ${reg.verifiedFqhn.replaceAll('.idr.to', '')}'
                        '${c.plan == IdrBusinessPlan.enterprise ? ' --org <org-slug>' : ''}',
            ),
          ),
        if (pending != null && pending.isNotEmpty)
          IdrCard(
            child: IdrTable(
              columns: const ['Request', 'Zone', 'Requester', 'Submitted', ''],
              rows: [
                for (final r in pending)
                  IdrTableRow(
                    onTap: c.busy ? null : () => _review(r),
                    cells: [
                      Text(requestLabel(r)),
                      Text(r.zone ?? '(root)'),
                      Text(r.requesterEmail.isEmpty ? '-' : r.requesterEmail),
                      Text(
                        '${r.submittedAt.toLocal()}'.split('.').first,
                        style: IdrText.body(size: 12, color: IdrColors.zinc500),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: IdrButton(
                          label: 'Review',
                          size: IdrButtonSize.xs,
                          onPressed: c.busy ? null : () => _review(r),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
