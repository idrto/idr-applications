import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../target/target_controller.dart';
import '../ui/components/buttons/idr_button.dart';
import '../ui/components/cards/idr_card.dart';
import '../ui/components/feedback/idr_feedback.dart';
import '../ui/components/layout/idr_layout.dart';
import '../ui/theme/idr_theme.dart';

/// Full-screen shell for pre-home screens (sign-in, setup, billing, register).
class FlowScaffold extends StatelessWidget {
  const FlowScaffold({
    super.key,
    required this.controller,
    required this.title,
    required this.child,
    this.subtitle,
    this.steps,
    this.step = 0,
    this.maxWidth = 460,
  });

  final TargetController controller;
  final String title;
  final String? subtitle;
  final Widget child;
  final List<String>? steps;
  final int step;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final s = controller.session;
    return Scaffold(
      backgroundColor: IdrColors.bg,
      body: Column(
        children: [
          IdrShellBar(
            title: 'Target',
            userInitial: s == null || s.email.isEmpty
                ? null
                : s.email[0].toUpperCase(),
            userLabel: s?.email,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(32, 32, 32, 40),
              children: [
                if (steps != null) _Progress(steps: steps!, step: step),
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(title, style: IdrText.display(size: 24)),
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle!,
                            style: IdrText.body(color: IdrColors.zinc500),
                          ),
                        ],
                        const SizedBox(height: 20),
                        ErrorBanner(controller: controller),
                        child,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.steps, required this.step});

  final List<String> steps;
  final int step;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Row(
            children: [
              for (var i = 0; i < steps.length; i++) ...[
                Column(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < step ? IdrColors.accent : Colors.white,
                        border: Border.all(
                          color: i <= step
                              ? IdrColors.accent
                              : IdrColors.zinc300,
                          width: i == step ? 2 : 1,
                        ),
                      ),
                      child: Text(
                        i < step ? '✓' : '${i + 1}',
                        style: IdrText.body(
                          size: 12,
                          weight: FontWeight.w600,
                          color: i < step
                              ? Colors.white
                              : i == step
                              ? IdrColors.accent
                              : IdrColors.zinc400,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      steps[i],
                      style: IdrText.body(
                        size: 12,
                        color: i == step ? IdrColors.accent : IdrColors.zinc400,
                      ),
                    ),
                  ],
                ),
                if (i < steps.length - 1)
                  Expanded(
                    child: Container(
                      height: 1,
                      margin: const EdgeInsets.only(bottom: 18),
                      color: i < step ? IdrColors.accent : IdrColors.zinc200,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the controller's last action error, with a dismiss action.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.controller});

  final TargetController controller;

  @override
  Widget build(BuildContext context) {
    final e = controller.error;
    if (e == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: IdrAlert(
        tone: IdrTone.error,
        title: 'That did not work',
        message: e,
        actions: IdrButton(
          label: 'Dismiss',
          size: IdrButtonSize.sm,
          onPressed: controller.clearError,
        ),
      ),
    );
  }
}

/// Dims the child and shows what the controller is busy with.
class BusyOverlay extends StatelessWidget {
  const BusyOverlay({super.key, required this.controller, required this.child});

  final TargetController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (controller.busy)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: const BoxDecoration(
                color: IdrColors.zinc900,
                border: Border(top: BorderSide(color: IdrColors.zinc700)),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${controller.busyLabel}…',
                    style: IdrText.body(size: 12, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Selectable value with a copy button (DNS records, FQHNs, SKIs).
class CopyValue extends StatelessWidget {
  const CopyValue({super.key, required this.value, this.label});

  final String value;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: SelectableText(value, style: IdrText.mono(size: 12))),
        const SizedBox(width: 6),
        InkWell(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${label ?? 'Value'} copied'),
                  duration: const Duration(seconds: 1),
                ),
              );
            }
          },
          child: const Icon(Icons.copy, size: 13, color: IdrColors.zinc400),
        ),
      ],
    );
  }
}

/// Selectable card used for a choice among a few options.
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({
    super.key,
    required this.title,
    required this.body,
    this.footnote,
    this.onTap,
    this.selected = false,
  });

  final String title;
  final String body;
  final String? footnote;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(IdrRadius.lg),
        border: Border.all(
          color: selected ? IdrColors.accent : Colors.transparent,
          width: 2,
        ),
      ),
      child: IdrCard(
        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: IdrText.display(size: 14)),
            const SizedBox(height: 8),
            Text(
              body,
              style: IdrText.body(
                size: 12,
                color: IdrColors.zinc500,
                height: 1.4,
              ),
            ),
            if (footnote != null) ...[
              const SizedBox(height: 12),
              Text(
                footnote!,
                style: IdrText.mono(size: 10, color: IdrColors.accent),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
