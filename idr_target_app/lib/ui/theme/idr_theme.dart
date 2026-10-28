import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Tokens from the IDR design system (Instrument Sans, Inter, JetBrains Mono).
abstract final class IdrColors {
  static const bg = Color(0xFFF7F7F8);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFFE2E2E6);
  static const text = Color(0xFF111113);
  static const muted = Color(0xFF6B7280);
  static const accent = Color(0xFF2563EB);
  static const accentHover = Color(0xFF1D4ED8);

  static const online = Color(0xFF16A34A);
  static const offline = Color(0xFFDC2626);
  static const warning = Color(0xFFD97706);
  static const relay = Color(0xFF0891B2);

  static const zinc50 = Color(0xFFFAFAFA);
  static const zinc100 = Color(0xFFF4F4F5);
  static const zinc200 = Color(0xFFE4E4E7);
  static const zinc300 = Color(0xFFD4D4D8);
  static const zinc400 = Color(0xFFA1A1AA);
  static const zinc500 = Color(0xFF71717A);
  static const zinc600 = Color(0xFF52525B);
  static const zinc700 = Color(0xFF3F3F46);
  static const zinc800 = Color(0xFF27272A);
  static const zinc900 = Color(0xFF18181B);

  static const blue50 = Color(0xFFEFF6FF);
  static const blue100 = Color(0xFFDBEAFE);
  static const blue500 = Color(0xFF3B82F6);
  static const blue700 = Color(0xFF1D4ED8);

  static const green50 = Color(0xFFF0FDF4);
  static const green100 = Color(0xFFDCFCE7);
  static const green200 = Color(0xFFBBF7D0);
  static const green600 = Color(0xFF16A34A);
  static const green700 = Color(0xFF15803D);
  static const green800 = Color(0xFF166534);

  static const red50 = Color(0xFFFEF2F2);
  static const red200 = Color(0xFFFECACA);
  static const red600 = Color(0xFFDC2626);
  static const red700 = Color(0xFFB91C1C);
  static const red800 = Color(0xFF991B1B);

  static const amber50 = Color(0xFFFFFBEB);
  static const amber200 = Color(0xFFFDE68A);
  static const amber400 = Color(0xFFFBBF24);
  static const amber600 = Color(0xFFD97706);
  static const amber700 = Color(0xFFB45309);
  static const amber800 = Color(0xFF92400E);

  static const cyan50 = Color(0xFFECFEFF);
  static const cyan100 = Color(0xFFCFFAFE);
  static const cyan700 = Color(0xFF0E7490);

  static const violet50 = Color(0xFFF5F3FF);
  static const violet700 = Color(0xFF6D28D9);

  static const purple50 = Color(0xFFFAF5FF);
  static const purple600 = Color(0xFF9333EA);
}

abstract final class IdrRadius {
  static const sm = 4.0;
  static const md = 6.0;
  static const lg = 8.0;
  static const xl = 12.0;
}

abstract final class IdrText {
  static TextStyle display({
    double size = 18,
    FontWeight weight = FontWeight.w600,
    Color color = IdrColors.text,
    double height = 1.2,
  }) => GoogleFonts.instrumentSans(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: height,
  );

  static TextStyle body({
    double size = 14,
    FontWeight weight = FontWeight.w400,
    Color color = IdrColors.zinc800,
    double? height,
    double? letterSpacing,
  }) => GoogleFonts.inter(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
  );

  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color color = IdrColors.zinc700,
  }) => GoogleFonts.jetBrainsMono(
    fontSize: size,
    fontWeight: weight,
    color: color,
  );
}

enum IdrTone { info, success, warning, error }

ThemeData idrTheme() {
  final body = GoogleFonts.interTextTheme().apply(
    bodyColor: IdrColors.text,
    displayColor: IdrColors.text,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: IdrColors.bg,
    canvasColor: IdrColors.surface,
    dividerColor: IdrColors.zinc200,
    colorScheme: const ColorScheme.light(
      primary: IdrColors.accent,
      onPrimary: Colors.white,
      secondary: IdrColors.relay,
      surface: IdrColors.surface,
      onSurface: IdrColors.text,
      error: IdrColors.offline,
      outline: IdrColors.border,
    ),
    textTheme: body.copyWith(
      headlineMedium: IdrText.display(size: 20),
      titleLarge: IdrText.display(size: 18),
      titleMedium: IdrText.display(size: 14, color: IdrColors.zinc700),
      bodyMedium: IdrText.body(color: IdrColors.zinc700, height: 1.5),
      bodySmall: IdrText.body(size: 12, color: IdrColors.muted),
      labelSmall: IdrText.body(
        size: 12,
        weight: FontWeight.w500,
        color: IdrColors.zinc500,
        letterSpacing: 0.4,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(5),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.all(IdrColors.zinc300),
    ),
    splashFactory: NoSplash.splashFactory,
    hoverColor: Colors.transparent,
    highlightColor: Colors.transparent,
    visualDensity: VisualDensity.compact,
  );
}
