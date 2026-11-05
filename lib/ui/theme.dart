import 'package:flutter/material.dart';

/// Inkwell's accent: a clean notebook green.
const Color kGreen = Color(0xFF00A82D);
const Color kGreenOnDark = Color(0xFF3DDC6B);

/// The dark navigation panel (same in light and dark mode).
const Color kSidebarBg = Color(0xFF22262A);
const Color kSidebarSelected = Color(0xFF343A3F);
const Color kOnSidebar = Color(0xFFE6E8EA);
const Color kMutedOnSidebar = Color(0xFF8E979F);

/// Kept for code that still references the old seed colour.
const Color kSeedColor = kGreen;

ColorScheme inkwellScheme(Brightness b) {
  final dark = b == Brightness.dark;
  final base = ColorScheme.fromSeed(seedColor: kGreen, brightness: b);
  return base.copyWith(
    primary: dark ? kGreenOnDark : kGreen,
    onPrimary: dark ? const Color(0xFF00210A) : Colors.white,
    primaryContainer: dark ? const Color(0xFF1E3B28) : const Color(0xFFE3F5E8),
    onPrimaryContainer: dark ? const Color(0xFFD7F5DF) : const Color(0xFF00290D),
    surface: dark ? const Color(0xFF1A1C1E) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF202326) : const Color(0xFFF7F8F7),
    surfaceContainer: dark ? const Color(0xFF25282B) : const Color(0xFFF2F4F3),
    surfaceContainerHigh: dark ? const Color(0xFF2B2F32) : const Color(0xFFEEF0EF),
    outlineVariant: dark ? const Color(0xFF3A3F43) : const Color(0xFFE1E4E2),
  );
}

ThemeData buildTheme(ColorScheme scheme) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 3,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      elevation: 0,
      height: 64,
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
  );
}
