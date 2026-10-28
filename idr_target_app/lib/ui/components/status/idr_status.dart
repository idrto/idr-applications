import 'package:flutter/material.dart';

import '../../theme/idr_theme.dart';

enum IdrStatus {
  online,
  offline,
  connecting,
  warning,
  relay,
  p2p,
  active,
  inactive,
  denied,
  verified,
}

class IdrStatusStyle {
  const IdrStatusStyle({
    required this.color,
    required this.background,
    required this.label,
  });

  final Color color;
  final Color background;
  final String label;

  static const _all = <IdrStatus, IdrStatusStyle>{
    IdrStatus.online: IdrStatusStyle(
      color: IdrColors.online,
      background: IdrColors.green50,
      label: 'Online',
    ),
    IdrStatus.offline: IdrStatusStyle(
      color: IdrColors.offline,
      background: IdrColors.red50,
      label: 'Offline',
    ),
    IdrStatus.connecting: IdrStatusStyle(
      color: IdrColors.accent,
      background: IdrColors.blue50,
      label: 'Connecting',
    ),
    IdrStatus.warning: IdrStatusStyle(
      color: IdrColors.warning,
      background: IdrColors.amber50,
      label: 'Warning',
    ),
    IdrStatus.relay: IdrStatusStyle(
      color: IdrColors.relay,
      background: IdrColors.cyan50,
      label: 'Relay',
    ),
    IdrStatus.p2p: IdrStatusStyle(
      color: IdrColors.online,
      background: IdrColors.green50,
      label: 'P2P',
    ),
    IdrStatus.active: IdrStatusStyle(
      color: IdrColors.online,
      background: IdrColors.green50,
      label: 'Active',
    ),
    IdrStatus.inactive: IdrStatusStyle(
      color: Color(0xFF9CA3AF),
      background: Color(0xFFF9FAFB),
      label: 'Inactive',
    ),
    IdrStatus.denied: IdrStatusStyle(
      color: IdrColors.offline,
      background: IdrColors.red50,
      label: 'Denied',
    ),
    IdrStatus.verified: IdrStatusStyle(
      color: IdrColors.online,
      background: IdrColors.green50,
      label: 'Verified',
    ),
  };

  static IdrStatusStyle of(IdrStatus status) => _all[status]!;
}

class IdrStatusDot extends StatelessWidget {
  const IdrStatusDot({super.key, required this.status, this.label});

  final IdrStatus status;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final style = IdrStatusStyle.of(status);
    final dot = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: style.color, shape: BoxShape.circle),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status == IdrStatus.connecting) _Pulse(child: dot) else dot,
        const SizedBox(width: 6),
        Text(
          label ?? style.label,
          style: IdrText.body(
            size: 12,
            weight: FontWeight.w500,
            color: style.color,
          ),
        ),
      ],
    );
  }
}

class IdrStatusBadge extends StatelessWidget {
  const IdrStatusBadge({super.key, required this.status, this.label});

  final IdrStatus status;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final style = IdrStatusStyle.of(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(IdrRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: style.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label ?? style.label,
            style: IdrText.body(
              size: 12,
              weight: FontWeight.w500,
              color: style.color,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_controller),
      child: widget.child,
    );
  }
}
