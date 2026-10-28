import 'package:flutter/material.dart';

import '../../theme/idr_theme.dart';

class IdrNavItem extends StatefulWidget {
  const IdrNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge,
    this.indent = false,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final int? badge;
  final bool indent;

  @override
  State<IdrNavItem> createState() => _IdrNavItemState();
}

class _IdrNavItemState extends State<IdrNavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final bg = active
        ? IdrColors.blue50
        : _hover
        ? IdrColors.zinc100
        // Transparent *of the hover color*: Colors.transparent is black, and
        // the tween would pass through dark grey.
        : IdrColors.zinc100.withValues(alpha: 0);
    final fg = active
        ? IdrColors.blue700
        : (_hover ? IdrColors.zinc900 : IdrColors.zinc600);
    final iconColor = active ? IdrColors.accent : IdrColors.zinc400;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(widget.indent ? 32 : 12, 6, 12, 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(IdrRadius.sm),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 14, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: IdrText.body(
                    weight: active ? FontWeight.w500 : FontWeight.w400,
                    color: fg,
                  ),
                ),
              ),
              if (widget.badge != null && widget.badge! > 0)
                Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: IdrColors.accent,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    '${widget.badge}',
                    style: IdrText.body(size: 12, color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class IdrNavGroup extends StatelessWidget {
  const IdrNavGroup({super.key, required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Text(
              label.toUpperCase(),
              style: IdrText.body(
                size: 10,
                weight: FontWeight.w700,
                color: IdrColors.zinc400,
                letterSpacing: 1.2,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class IdrSideNav extends StatelessWidget {
  const IdrSideNav({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.footer,
    this.width = 176,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Widget? footer;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: IdrColors.zinc200)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: IdrColors.zinc100)),
              ),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: IdrText.display(size: 12)),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: IdrText.body(size: 10, color: IdrColors.zinc400),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: children),
          ),
          if (footer != null) ...[
            const Divider(height: 17, color: IdrColors.zinc100),
            footer!,
          ],
        ],
      ),
    );
  }
}
