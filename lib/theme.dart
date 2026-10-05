import 'package:flutter/material.dart';

// Tuxedo-cat palette, sampled from Lamar's sprite.
const tuxBlack = Color(0xFF1A1A1A); // fur
const tuxCream = Color(0xFFFBFAF6); // bib and paws
const tuxPink = Color(0xFFE07F70); // nose and inner ears
const tuxEye = Color(0xFFC4C639); // eyes

ThemeData buildTheme(Brightness brightness) {
  final light = brightness == Brightness.light;

  // Monochrome base (black and white), with Lamar's pink and eye colour as accents.
  final scheme =
      ColorScheme.fromSeed(
        seedColor: tuxBlack,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      ).copyWith(
        primary: light ? tuxBlack : const Color(0xFFF4F1EA),
        onPrimary: light ? Colors.white : tuxBlack,
        primaryContainer: light ? const Color(0xFFECE8DF) : const Color(0xFF2B2A28),
        onPrimaryContainer: light ? tuxBlack : const Color(0xFFF4F1EA),
        secondary: light ? const Color(0xFFC9604F) : const Color(0xFFF2A398),
        onSecondary: light ? Colors.white : const Color(0xFF4A1E17),
        secondaryContainer: light ? const Color(0xFFFBE1DC) : const Color(0xFF5A2E28),
        onSecondaryContainer: light ? const Color(0xFF5A2E28) : const Color(0xFFFBE1DC),
        tertiary: light ? const Color(0xFF7D7F10) : const Color(0xFFD4D65A),
        tertiaryContainer: light ? const Color(0xFFEEF0C2) : const Color(0xFF3E3F0A),
        onTertiaryContainer: light ? const Color(0xFF3E3F0A) : const Color(0xFFEEF0C2),
        surface: light ? tuxCream : const Color(0xFF131313),
      );

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.3,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
    ),
    // Black-tie buttons: solid black FAB with a cream label.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    tabBarTheme: TabBarThemeData(
      indicatorColor: scheme.secondary,
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    chipTheme: base.chipTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}
