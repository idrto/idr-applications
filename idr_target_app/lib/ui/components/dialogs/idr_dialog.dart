import 'package:flutter/material.dart';

import '../../theme/idr_theme.dart';

Future<T?> showIdrDialog<T>({
  required BuildContext context,
  required String title,
  required Widget content,
  double maxWidth = 448,
}) {
  return showDialog<T>(
    context: context,
    barrierColor: const Color(0x33000000),
    builder: (context) {
      return Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(IdrRadius.xl),
          side: const BorderSide(color: IdrColors.zinc200),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title, style: IdrText.display(size: 14)),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close,
                        size: 16,
                        color: IdrColors.zinc400,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: IdrColors.zinc200),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: content,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
