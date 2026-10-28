import 'package:flutter/material.dart';

import '../../theme/idr_theme.dart';

class IdrCard extends StatefulWidget {
  const IdrCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  State<IdrCard> createState() => _IdrCardState();
}

class _IdrCardState extends State<IdrCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final tappable = widget.onTap != null;
    final hover = _hover && tappable;
    return MouseRegion(
      cursor: tappable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(IdrRadius.lg),
            border: Border.all(
              color: hover ? IdrColors.zinc300 : IdrColors.zinc200,
            ),
            boxShadow: hover
                ? const [
                    BoxShadow(
                      color: Color(0x0D000000),
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

enum IdrStatTone { neutral, accent, warn }

class IdrStatCard extends StatelessWidget {
  const IdrStatCard({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.tone = IdrStatTone.neutral,
  });

  final String label;
  final String value;
  final String? sub;
  final IdrStatTone tone;

  @override
  Widget build(BuildContext context) {
    final valueColor = switch (tone) {
      IdrStatTone.neutral => IdrColors.text,
      IdrStatTone.accent => IdrColors.accent,
      IdrStatTone.warn => IdrColors.warning,
    };
    return IdrCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: IdrText.body(
              size: 12,
              weight: FontWeight.w500,
              color: IdrColors.zinc500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: IdrText.display(size: 24, color: valueColor, height: 1),
          ),
          if (sub != null) ...[
            const SizedBox(height: 4),
            Text(sub!, style: IdrText.body(size: 12, color: IdrColors.zinc400)),
          ],
        ],
      ),
    );
  }
}

class IdrTableRow {
  const IdrTableRow({required this.cells, this.onTap});

  final List<Widget> cells;
  final VoidCallback? onTap;
}

class IdrTable extends StatelessWidget {
  const IdrTable({super.key, required this.columns, required this.rows});

  final List<String> columns;
  final List<IdrTableRow> rows;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  decoration: const BoxDecoration(
                    color: Color(0xFFFCFCFC),
                    border: Border(
                      bottom: BorderSide(color: IdrColors.zinc200),
                    ),
                  ),
                  children: [
                    for (final column in columns)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Text(
                          column.toUpperCase(),
                          style: IdrText.body(
                            size: 12,
                            weight: FontWeight.w600,
                            color: IdrColors.zinc500,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                  ],
                ),
                for (final row in rows) _dataRow(row),
              ],
            ),
          ),
        );
      },
    );
  }

  TableRow _dataRow(IdrTableRow row) {
    return TableRow(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: IdrColors.zinc100)),
      ),
      children: [
        for (var i = 0; i < columns.length; i++)
          TableRowInkWell(
            onTap: row.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: i < row.cells.length
                  ? DefaultTextStyle(
                      style: IdrText.body(color: IdrColors.zinc800),
                      child: row.cells[i],
                    )
                  : const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }
}
