import 'package:flutter/material.dart';

import '../../theme/idr_theme.dart';

class IdrMark extends StatelessWidget {
  const IdrMark({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: IdrColors.zinc900,
        borderRadius: BorderRadius.circular(
          size > 24 ? IdrRadius.lg : IdrRadius.sm,
        ),
      ),
      child: Text(
        'IDR',
        style: IdrText.display(
          size: size * 0.4,
          color: Colors.white,
          height: 1,
        ),
      ),
    );
  }
}

class IdrShellBar extends StatelessWidget {
  const IdrShellBar({
    super.key,
    required this.title,
    this.tag,
    this.onBack,
    this.userInitial,
    this.userLabel,
    this.orgLabel,
  });

  final String title;
  final String? tag;
  final VoidCallback? onBack;
  final String? userInitial;
  final String? userLabel;
  final String? orgLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: IdrColors.zinc200)),
      ),
      child: Row(
        children: [
          if (onBack != null) _BarButton(label: '← Back', onTap: onBack!),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: IdrColors.zinc200)),
            ),
            child: Row(
              children: [
                const IdrMark(),
                const SizedBox(width: 8),
                Text('IDR', style: IdrText.display(size: 14)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text(
            title,
            style: IdrText.body(
              weight: FontWeight.w500,
              color: IdrColors.zinc700,
            ),
          ),
          if (tag != null) ...[const SizedBox(width: 8), IdrTag(label: tag!)],
          const Spacer(),
          if (userInitial != null) ...[
            CircleAvatar(
              radius: 12,
              backgroundColor: IdrColors.blue100,
              child: Text(
                userInitial!,
                style: IdrText.body(
                  size: 12,
                  weight: FontWeight.w700,
                  color: IdrColors.blue700,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (userLabel != null)
            Text(
              userLabel!,
              style: IdrText.body(size: 12, color: IdrColors.zinc600),
            ),
          if (orgLabel != null) ...[
            Text(
              ' · ',
              style: IdrText.body(size: 12, color: IdrColors.zinc400),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                orgLabel!,
                style: IdrText.body(size: 12, color: IdrColors.zinc400),
              ),
            ),
          ] else
            const SizedBox(width: 16),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          border: Border(right: BorderSide(color: IdrColors.zinc200)),
        ),
        child: Text(
          label,
          style: IdrText.body(size: 12, color: IdrColors.zinc500),
        ),
      ),
    );
  }
}

class IdrTag extends StatelessWidget {
  const IdrTag({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: IdrColors.zinc100,
        borderRadius: BorderRadius.circular(IdrRadius.sm),
      ),
      child: Text(
        label.toUpperCase(),
        style: IdrText.body(
          size: 10,
          weight: FontWeight.w600,
          color: IdrColors.zinc400,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class IdrPageHeader extends StatelessWidget {
  const IdrPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
  });

  final String title;
  final String? subtitle;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: IdrText.display()),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: IdrText.body(size: 12, color: IdrColors.zinc500),
                  ),
                ],
              ],
            ),
          ),
          if (actions != null) ...[const SizedBox(width: 16), actions!],
        ],
      ),
    );
  }
}

class IdrSectionTitle extends StatelessWidget {
  const IdrSectionTitle({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        label.toUpperCase(),
        style: IdrText.body(
          size: 12,
          weight: FontWeight.w600,
          color: IdrColors.zinc500,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class IdrInfoRow extends StatelessWidget {
  const IdrInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
    this.divider = false,
  });

  final String label;
  final Widget value;
  final bool mono;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: divider
          ? const BoxDecoration(
              border: Border(bottom: BorderSide(color: IdrColors.zinc100)),
            )
          : null,
      child: Row(
        children: [
          SizedBox(
            width: 144,
            child: Text(
              label,
              style: IdrText.body(size: 12, color: IdrColors.zinc500),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: DefaultTextStyle(
                style: mono
                    ? IdrText.mono(color: IdrColors.zinc800)
                    : IdrText.body(color: IdrColors.zinc800),
                textAlign: TextAlign.right,
                child: value,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class IdrInfoGroup extends StatelessWidget {
  const IdrInfoGroup({super.key, required this.rows});

  final List<IdrInfoRow> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++)
          IdrInfoRow(
            label: rows[i].label,
            value: rows[i].value,
            mono: rows[i].mono,
            divider: i != rows.length - 1,
          ),
      ],
    );
  }
}
