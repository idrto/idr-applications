import 'package:flutter/material.dart';

import '../../theme/idr_theme.dart';

InputDecoration idrInputDecoration({
  String? hint,
  Widget? prefix,
  bool readOnly = false,
}) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(IdrRadius.sm),
    borderSide: BorderSide(
      color: readOnly ? IdrColors.zinc200 : IdrColors.zinc300,
    ),
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: IdrText.body(color: IdrColors.zinc400),
    isDense: true,
    filled: true,
    fillColor: readOnly ? IdrColors.zinc50 : Colors.white,
    contentPadding: EdgeInsets.fromLTRB(prefix == null ? 12 : 0, 8, 12, 8),
    prefixIcon: prefix,
    prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    constraints: const BoxConstraints(minHeight: 32),
    border: border,
    enabledBorder: border,
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(IdrRadius.sm),
      borderSide: const BorderSide(color: IdrColors.accent),
    ),
    disabledBorder: border,
  );
}

class IdrTextField extends StatelessWidget {
  const IdrTextField({
    super.key,
    this.controller,
    this.value,
    this.hint,
    this.onChanged,
    this.obscure = false,
    this.readOnly = false,
    this.mono = false,
    this.keyboardType,
  }) : assert(
         controller == null || value == null,
         'Pass a controller or a value, not both.',
       );

  final TextEditingController? controller;
  final String? value;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final bool obscure;
  final bool readOnly;
  final bool mono;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final style = mono
        ? IdrText.mono(size: 12, color: IdrColors.text)
        : IdrText.body(color: IdrColors.text);
    return TextFormField(
      controller: controller,
      initialValue: controller == null ? value : null,
      onChanged: onChanged,
      obscureText: obscure,
      readOnly: readOnly,
      keyboardType: keyboardType,
      style: style,
      cursorColor: IdrColors.accent,
      decoration: idrInputDecoration(hint: hint, readOnly: readOnly),
    );
  }
}

class IdrSearchField extends StatelessWidget {
  const IdrSearchField({super.key, this.controller, this.hint, this.onChanged});

  final TextEditingController? controller;
  final String? hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: IdrText.body(color: IdrColors.text),
      cursorColor: IdrColors.accent,
      decoration: idrInputDecoration(
        hint: hint,
        prefix: const Icon(Icons.search, size: 13, color: IdrColors.zinc400),
      ),
    );
  }
}

class IdrOption<T> {
  const IdrOption({required this.value, required this.label});

  final T value;
  final String label;
}

class IdrSelect<T> extends StatelessWidget {
  const IdrSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<IdrOption<T>> options;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: idrInputDecoration().copyWith(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      isEmpty: false,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 16,
            color: IdrColors.zinc500,
          ),
          style: IdrText.body(color: IdrColors.text),
          items: [
            for (final option in options)
              DropdownMenuItem<T>(
                value: option.value,
                child: Text(
                  option.label,
                  style: IdrText.body(color: IdrColors.text),
                ),
              ),
          ],
          onChanged: onChanged == null
              ? null
              : (next) {
                  if (next != null) onChanged!(next);
                },
        ),
      ),
    );
  }
}

class IdrField extends StatelessWidget {
  const IdrField({
    super.key,
    required this.label,
    required this.child,
    this.hint,
    this.required = false,
  });

  final String label;
  final Widget child;
  final String? hint;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IdrFieldLabel(label: label, required: required),
        const SizedBox(height: 4),
        child,
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint!,
            style: IdrText.body(
              size: 12,
              color: IdrColors.zinc400,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

class IdrFieldLabel extends StatelessWidget {
  const IdrFieldLabel({super.key, required this.label, this.required = false});

  final String label;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: label,
        style: IdrText.body(
          size: 12,
          weight: FontWeight.w500,
          color: IdrColors.zinc600,
        ),
        children: [
          if (required)
            TextSpan(
              text: ' *',
              style: IdrText.body(
                size: 12,
                weight: FontWeight.w500,
                color: IdrColors.offline,
              ),
            ),
        ],
      ),
    );
  }
}

class IdrTabs extends StatelessWidget {
  const IdrTabs({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.onChanged,
  });

  final List<IdrTab> tabs;
  final String activeId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ColoredBox(
            color: IdrColors.zinc200,
            child: SizedBox(height: 1),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final tab in tabs)
                _Tab(
                  tab: tab,
                  active: tab.id == activeId,
                  onTap: () => onChanged(tab.id),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class IdrTab {
  const IdrTab({required this.id, required this.label, this.count});

  final String id;
  final String label;
  final int? count;
}

class _Tab extends StatelessWidget {
  const _Tab({required this.tab, required this.active, required this.onTap});

  final IdrTab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? IdrColors.accent : IdrColors.zinc500;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? IdrColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Text(
              tab.label,
              style: IdrText.body(weight: FontWeight.w500, color: color),
            ),
            if (tab.count != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: active ? IdrColors.blue100 : IdrColors.zinc100,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '${tab.count}',
                  style: IdrText.body(
                    size: 12,
                    color: active ? IdrColors.blue700 : IdrColors.zinc500,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
