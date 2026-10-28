import 'package:flutter/material.dart';

import '../../theme/idr_theme.dart';

enum IdrButtonVariant { primary, secondary, tertiary, destructive, ghost }

enum IdrButtonSize { xs, sm, md, lg }

class IdrButton extends StatefulWidget {
  const IdrButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = IdrButtonVariant.secondary,
    this.size = IdrButtonSize.md,
    this.icon,
    this.loading = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IdrButtonVariant variant;
  final IdrButtonSize size;
  final IconData? icon;
  final bool loading;
  final bool expand;

  @override
  State<IdrButton> createState() => _IdrButtonState();
}

class _IdrButtonState extends State<IdrButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    final hover = _hover && enabled;
    final (bg, fg, border) = _paint(widget.variant, hover);
    final (height, hPad, font, iconSize) = _metrics(widget.size);

    final button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? widget.onPressed : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: height,
            padding: EdgeInsets.symmetric(horizontal: hPad),
            alignment: widget.expand ? Alignment.center : null,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(IdrRadius.sm),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.loading)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                  )
                else if (widget.icon != null)
                  Icon(widget.icon, size: iconSize, color: fg),
                if ((widget.loading || widget.icon != null) &&
                    widget.label.isNotEmpty)
                  const SizedBox(width: 6),
                if (widget.label.isNotEmpty)
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: IdrText.body(
                        size: font,
                        weight: FontWeight.w500,
                        color: fg,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!widget.expand) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}

(Color, Color, Color) _paint(IdrButtonVariant variant, bool hover) {
  return switch (variant) {
    IdrButtonVariant.primary => (
      hover ? IdrColors.accentHover : IdrColors.accent,
      Colors.white,
      hover ? IdrColors.accentHover : IdrColors.accent,
    ),
    IdrButtonVariant.secondary => (
      hover ? IdrColors.zinc50 : Colors.white,
      IdrColors.zinc800,
      IdrColors.zinc300,
    ),
    IdrButtonVariant.tertiary => (
      hover ? IdrColors.zinc200 : IdrColors.zinc100,
      IdrColors.zinc700,
      Colors.transparent,
    ),
    IdrButtonVariant.destructive => (
      hover ? IdrColors.red700 : IdrColors.offline,
      Colors.white,
      hover ? IdrColors.red700 : IdrColors.offline,
    ),
    IdrButtonVariant.ghost => (
      hover ? IdrColors.zinc100 : IdrColors.zinc100.withValues(alpha: 0),
      IdrColors.zinc600,
      Colors.transparent,
    ),
  };
}

(double, double, double, double) _metrics(IdrButtonSize size) {
  return switch (size) {
    IdrButtonSize.xs => (24, 8, 12, 12),
    IdrButtonSize.sm => (28, 10, 12, 12),
    IdrButtonSize.md => (32, 14, 14, 14),
    IdrButtonSize.lg => (36, 16, 14, 14),
  };
}
