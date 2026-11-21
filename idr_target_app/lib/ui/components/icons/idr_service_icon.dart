import 'package:material_ui/material_ui.dart';

import '../../theme/idr_theme.dart';

enum IdrServiceKind { model, database, http }

class IdrServiceIcon extends StatelessWidget {
  const IdrServiceIcon({super.key, required this.kind, this.size = 32});

  final IdrServiceKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (kind) {
      IdrServiceKind.model => (
        IdrColors.purple50,
        IdrColors.purple600,
        Icons.memory,
      ),
      IdrServiceKind.database => (
        IdrColors.blue50,
        IdrColors.accent,
        Icons.storage_outlined,
      ),
      IdrServiceKind.http => (
        IdrColors.zinc100,
        IdrColors.zinc500,
        Icons.public,
      ),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(IdrRadius.md),
      ),
      child: Icon(icon, size: size * 0.47, color: fg),
    );
  }
}
