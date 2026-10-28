import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/idr_theme.dart';

class IdrAlert extends StatelessWidget {
  const IdrAlert({
    super.key,
    required this.tone,
    required this.title,
    this.message,
    this.actions,
  });

  final IdrTone tone;
  final String title;
  final String? message;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final (bg, border, color, icon) = switch (tone) {
      IdrTone.info => (
        IdrColors.blue50,
        const Color(0xFFBFDBFE),
        IdrColors.blue700,
        'ℹ',
      ),
      IdrTone.warning => (
        IdrColors.amber50,
        IdrColors.amber200,
        IdrColors.amber800,
        '⚠',
      ),
      IdrTone.error => (
        IdrColors.red50,
        IdrColors.red200,
        IdrColors.red800,
        '✕',
      ),
      IdrTone.success => (
        IdrColors.green50,
        IdrColors.green200,
        IdrColors.green800,
        '✓',
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(IdrRadius.lg),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            icon,
            style: IdrText.body(weight: FontWeight.w600, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: IdrText.body(weight: FontWeight.w600, color: color),
                ),
                if (message != null)
                  Text(
                    message!,
                    style: IdrText.body(
                      size: 12,
                      color: color.withValues(alpha: 0.8),
                    ),
                  ),
              ],
            ),
          ),
          if (actions != null) ...[const SizedBox(width: 12), actions!],
        ],
      ),
    );
  }
}

class IdrEmpty extends StatelessWidget {
  const IdrEmpty({
    super.key,
    required this.title,
    this.icon,
    this.description,
    this.action,
  });

  final IconData? icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 32, color: const Color(0xFFE4E4E7)),
            const SizedBox(height: 16),
          ],
          Text(
            title,
            textAlign: TextAlign.center,
            style: IdrText.display(size: 14, color: IdrColors.zinc600),
          ),
          if (description != null) ...[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                description!,
                textAlign: TextAlign.center,
                style: IdrText.body(
                  size: 12,
                  color: IdrColors.zinc400,
                  height: 1.4,
                ),
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

enum IdrStepStatus { done, active, pending, error }

class IdrStepRow extends StatelessWidget {
  const IdrStepRow({
    super.key,
    required this.label,
    required this.status,
    this.detail,
  });

  final String label;
  final IdrStepStatus status;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final (mark, color) = switch (status) {
      IdrStepStatus.done => ('✓', IdrColors.online),
      IdrStepStatus.active => ('·', IdrColors.accent),
      IdrStepStatus.pending => ('·', const Color(0xFFD1D5DB)),
      IdrStepStatus.error => ('✕', IdrColors.offline),
    };
    final labelColor = switch (status) {
      IdrStepStatus.active => IdrColors.text,
      IdrStepStatus.done => IdrColors.zinc600,
      IdrStepStatus.pending => const Color(0xFFD4D4D8),
      IdrStepStatus.error => IdrColors.offline,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Text(
              mark,
              textAlign: TextAlign.right,
              style: IdrText.mono(
                size: 14,
                weight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: IdrText.body(
                color: labelColor,
                weight: status == IdrStepStatus.active
                    ? FontWeight.w500
                    : FontWeight.w400,
              ),
            ),
          ),
          if (status == IdrStepStatus.active)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: IdrColors.blue500,
              ),
            )
          else if (status == IdrStepStatus.done && detail != null)
            Text(
              detail!,
              style: IdrText.body(size: 12, color: IdrColors.zinc400),
            ),
        ],
      ),
    );
  }
}

class IdrAccordion extends StatefulWidget {
  const IdrAccordion({
    super.key,
    required this.label,
    required this.child,
    this.initiallyOpen = false,
  });

  final String label;
  final Widget child;
  final bool initiallyOpen;

  @override
  State<IdrAccordion> createState() => _IdrAccordionState();
}

class _IdrAccordionState extends State<IdrAccordion> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: IdrColors.zinc200),
        borderRadius: BorderRadius.circular(IdrRadius.lg),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Material(
            color: IdrColors.zinc50,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.label.toUpperCase(),
                        style: IdrText.body(
                          size: 12,
                          weight: FontWeight.w600,
                          color: IdrColors.zinc600,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: const Icon(
                        Icons.keyboard_arrow_down,
                        size: 14,
                        color: IdrColors.zinc400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            Padding(padding: const EdgeInsets.all(16), child: widget.child),
        ],
      ),
    );
  }
}

class IdrToastData {
  const IdrToastData({
    required this.id,
    required this.tone,
    required this.message,
  });

  final String id;
  final IdrTone tone;
  final String message;
}

class IdrToast extends StatefulWidget {
  const IdrToast({super.key, required this.data, required this.onClose});

  final IdrToastData data;
  final VoidCallback onClose;

  @override
  State<IdrToast> createState() => _IdrToastState();
}

class _IdrToastState extends State<IdrToast> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 4), widget.onClose);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (bg, border, color, icon) = switch (widget.data.tone) {
      IdrTone.success => (
        IdrColors.green50,
        IdrColors.green200,
        IdrColors.green700,
        '✓',
      ),
      IdrTone.error => (
        IdrColors.red50,
        IdrColors.red200,
        IdrColors.red600,
        '✕',
      ),
      IdrTone.warning => (
        IdrColors.amber50,
        IdrColors.amber200,
        IdrColors.warning,
        '⚠',
      ),
      IdrTone.info => (
        IdrColors.blue50,
        const Color(0xFFBFDBFE),
        IdrColors.accent,
        'i',
      ),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(IdrRadius.lg),
          border: Border.all(color: border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 16,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Text(icon, style: IdrText.body(color: color)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.data.message,
                style: IdrText.body(weight: FontWeight.w500, color: color),
              ),
            ),
            GestureDetector(
              onTap: widget.onClose,
              child: Text(
                '✕',
                style: IdrText.body(
                  size: 12,
                  color: color.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class IdrToastHost extends StatelessWidget {
  const IdrToastHost({
    super.key,
    required this.child,
    required this.toasts,
    required this.onClose,
  });

  final Widget child;
  final List<IdrToastData> toasts;
  final ValueChanged<String> onClose;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          right: 20,
          bottom: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final toast in toasts)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: IdrToast(
                    key: ValueKey(toast.id),
                    data: toast,
                    onClose: () => onClose(toast.id),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
