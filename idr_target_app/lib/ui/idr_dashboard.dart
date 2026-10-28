import 'package:flutter/material.dart';

import 'components/layout/idr_layout.dart';
import 'components/navigation/idr_nav.dart';
import 'theme/idr_theme.dart';

class IdrDashItem {
  const IdrDashItem(this.id, this.label, this.icon, {this.badge});

  final String id;
  final String label;
  final IconData icon;
  final int? badge;
}

class IdrDashGroup {
  const IdrDashGroup(this.label, this.items);

  final String label;
  final List<IdrDashItem> items;
}

/// Left-nav shell used by the Target, Source, Enterprise, and Provider dashboards.
class IdrDashboard extends StatelessWidget {
  const IdrDashboard({
    super.key,
    required this.title,
    required this.tag,
    required this.navTitle,
    required this.nav,
    required this.section,
    required this.onSection,
    this.onBack,
    required this.body,
    this.navSubtitle,
    this.navWidth = 192,
    this.userInitial,
    this.userLabel,
    this.orgLabel,
    this.footer,
  });

  final String title;
  final String tag;
  final String navTitle;
  final String? navSubtitle;
  final List<IdrDashGroup> nav;
  final String section;
  final ValueChanged<String> onSection;
  final VoidCallback? onBack;
  final Widget body;
  final double navWidth;
  final String? userInitial;
  final String? userLabel;
  final String? orgLabel;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: IdrColors.bg,
      body: Column(
        children: [
          IdrShellBar(
            title: title,
            tag: tag,
            onBack: onBack,
            userInitial: userInitial,
            userLabel: userLabel,
            orgLabel: orgLabel,
          ),
          Expanded(
            child: Row(
              children: [
                IdrSideNav(
                  title: navTitle,
                  subtitle: navSubtitle,
                  width: navWidth,
                  footer: footer,
                  children: [
                    for (final group in nav)
                      IdrNavGroup(
                        label: group.label,
                        children: [
                          for (final item in group.items)
                            IdrNavItem(
                              icon: item.icon,
                              label: item.label,
                              badge: item.badge,
                              active: item.id == section,
                              onTap: () => onSection(item.id),
                            ),
                        ],
                      ),
                  ],
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [body],
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

class IdrStatGrid extends StatelessWidget {
  const IdrStatGrid({super.key, required this.children, this.columns = 4});

  final List<Widget> children;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth < 760 ? 2 : columns;
        final width = (constraints.maxWidth - 12 * (cols - 1)) / cols;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}
