// FILE: lib/theme/app_theme.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// Defines the visual identity of the LoadOut app — colors, typography,
// component shapes, button sizing, input field styling, navigation bar
// appearance, dialog corner radii, snackbar behavior, and so on. The whole
// file is one Dart class, `AppTheme`, that exposes two static getters:
// `AppTheme.dark` and `AppTheme.light`. Each returns a fully-configured
// Flutter `ThemeData` object. `MaterialApp` (in `app.dart`) reads these
// and propagates them down through `Theme.of(context)` so every widget
// picks up consistent styling without having to specify colors locally.
//
// The brand palette is brass + gunmetal: a warm metallic gold (`#C5A572`)
// against a deep cool charcoal (`#1F2937`). These two colors evoke
// reloading-bench aesthetics — brass cartridge cases on a gun-blue
// surface — and are the canonical reference for any new UI work.
// Variations (`brassHighlight`, `brassDeep`, `gunmetalSurface`,
// `gunmetalSurfaceHigh`, `parchment`, `oxblood`) are the sanctioned
// derivatives for accents, surfaces, and error states.
//
// Both themes use Material 3 (`useMaterial3: true`), Google's current
// design system. `ColorScheme.fromSeed(...)` is a Material 3 helper that
// algorithmically generates a tonal palette around a seed color (here,
// `brass`); the explicit overrides after that lock in the exact brand
// values rather than letting the algorithm pick. The shared
// `_buildTheme()` method then takes a finished color scheme and applies
// component-level overrides (button heights, input border radii, card
// shapes) so dark and light render with the same geometry, just different
// pigments.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// Without a centralized theme, every screen and button would have to
// hand-pick colors and dimensions, and the app would drift visually as
// new code lands. By funnelling all styling decisions through this file,
// a one-line tweak here propagates to every button in the app, and the
// brand stays internally consistent.
//
// Both `dark` and `light` are exposed even though the app defaults to
// dark mode (`themeMode: ThemeMode.dark` in `app.dart`). The light theme
// exists because Material 3 best practice — and Apple's HIG — is to
// honour the system appearance toggle. Even though dark is the canonical
// look, a user who has the OS in light mode sees the light variant when
// the app supplies one.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
// Material 3's `ColorScheme.fromSeed` is opinionated and will pick its own
// secondary/tertiary colors that may not match your brand. The pattern
// here — passing a seed and then explicitly overriding `primary`,
// `secondary`, `surface`, etc. — is the prescribed way to keep the
// generated tonal ramps useful for things like ripples and elevated
// surfaces while still locking the brand colors that matter most.
//
// `Color.withValues(alpha: ...)` is the Material 3 / Flutter 3.27+
// replacement for the older `withOpacity()`. It uses a wider color gamut
// representation that doesn't lose precision. Switching back to
// `withOpacity()` will produce a deprecation warning in `flutter analyze`.
//
// The serif font is declared as just `'serif'` rather than a specific
// family — that defers to whatever the platform's default serif is (New
// York / Times on iOS, Noto Serif or platform default on Android). This
// avoids bundling a custom font and keeps the binary small, but it does
// mean the headlines look subtly different on each platform.
//
// `WidgetStateProperty` (formerly `MaterialStateProperty`) is how Material
// 3 lets a property vary by state (selected/hovered/disabled/etc.). The
// nav bar's `iconTheme` uses it to brighten icons when selected without
// duplicating the theme entry.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
// - `lib/app.dart` — wires `AppTheme.dark` and `AppTheme.light` into
//   `MaterialApp`'s `theme` and `darkTheme` slots.
// - `lib/screens/disclaimer/disclaimer_screen.dart` and other screens
//   that reach for brand colors directly (e.g. for accent borders or
//   custom paint) import `AppTheme` and read constants like
//   `AppTheme.brass`, `AppTheme.gunmetal`.
// - Indirectly: every widget that calls `Theme.of(context)` or uses any
//   themable Material widget (Button, Card, AppBar, NavigationBar,
//   Dialog, SnackBar, TextField) picks up the styling defined here.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
// None — pure data. The static getters allocate fresh `ThemeData` objects
// on each call but perform no I/O, no platform calls, no persistence.
// They are safe to call from any context.

import 'package:flutter/material.dart';

/// LoadOut visual identity. Brass + gunmetal palette — see `ROADMAP.md`
/// "Design language" section. Dark theme is the default (matches the
/// app icon and sign-in screen and most users' system preference); a
/// matching light theme exists for users who flip system appearance.
class AppTheme {
  // Brand palette — keep these the canonical reference for any new UI.
  static const Color brass = Color(0xFFC5A572);
  static const Color brassHighlight = Color(0xFFEBBF74);
  static const Color brassDeep = Color(0xFF8A6F3F);
  static const Color gunmetal = Color(0xFF1F2937);
  static const Color gunmetalDeep = Color(0xFF161F2B);
  static const Color gunmetalSurface = Color(0xFF2A3441);
  static const Color gunmetalSurfaceHigh = Color(0xFF394656);
  static const Color parchment = Color(0xFFFAF7F0);
  static const Color parchmentSurface = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF1F2937);
  static const Color oxblood = Color(0xFF7B2D2D);

  // ─────────────────────────── Dark (default) ───────────────────────────

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: brass,
      brightness: Brightness.dark,
      primary: brass,
      onPrimary: gunmetalDeep,
      secondary: brassHighlight,
      onSecondary: gunmetalDeep,
      surface: gunmetal,
      onSurface: const Color(0xFFF5F5F5),
      surfaceContainer: gunmetalSurface,
      surfaceContainerHigh: gunmetalSurfaceHigh,
      error: const Color(0xFFE57373),
      onError: gunmetalDeep,
      outline: const Color(0xFF4A5566),
    );
    return _buildTheme(scheme);
  }

  // ─────────────────────────── Light (opt-in) ───────────────────────────

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: brass,
      brightness: Brightness.light,
      primary: brassDeep,
      onPrimary: Colors.white,
      secondary: gunmetal,
      onSecondary: Colors.white,
      surface: parchment,
      onSurface: ink,
      surfaceContainer: parchmentSurface,
      error: oxblood,
      onError: Colors.white,
    );
    return _buildTheme(scheme);
  }

  // ─────────────────────────── Shared component overrides ───────────────────────────

  static ThemeData _buildTheme(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: _textTheme(scheme),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: _serif,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.3)),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.6)),
          textStyle: const TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? scheme.surfaceContainer
            : scheme.surfaceContainer.withValues(alpha: 0.6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.4)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.4)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        labelStyle: TextStyle(color: scheme.onSurface.withValues(alpha: 0.75)),
        helperStyle: TextStyle(color: scheme.onSurface.withValues(alpha: 0.55)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.7),
          );
        }),
        height: 72,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outline.withValues(alpha: 0.25),
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurface.withValues(alpha: 0.7),
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface,
        ),
        subtitleTextStyle: TextStyle(
          fontSize: 13,
          color: scheme.onSurface.withValues(alpha: 0.65),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: TextStyle(color: scheme.onSurface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  // System serif for display/heading text. iOS: New York / Times.
  // Android: Noto Serif (or platform default serif).
  static const String _serif = 'serif';

  static TextTheme _textTheme(ColorScheme scheme) {
    final base = ThemeData(brightness: scheme.brightness).textTheme;
    final onSurface = scheme.onSurface;
    return base.copyWith(
      // Display + headline use serif for editorial weight on hero text.
      displayLarge: base.displayLarge?.copyWith(
        fontFamily: _serif,
        fontWeight: FontWeight.w400,
        color: onSurface,
        letterSpacing: -0.5,
      ),
      displayMedium: base.displayMedium?.copyWith(
        fontFamily: _serif,
        fontWeight: FontWeight.w400,
        color: onSurface,
      ),
      displaySmall: base.displaySmall?.copyWith(
        fontFamily: _serif,
        fontWeight: FontWeight.w500,
        color: onSurface,
      ),
      headlineLarge: base.headlineLarge?.copyWith(
        fontFamily: _serif,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontFamily: _serif,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontFamily: _serif,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      // Title sizes stay sans for UI density readability.
      titleLarge: base.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      // Body uses sans (system default) for density.
      bodyLarge: base.bodyLarge?.copyWith(color: onSurface),
      bodyMedium: base.bodyMedium?.copyWith(
        color: onSurface.withValues(alpha: 0.85),
      ),
      bodySmall: base.bodySmall?.copyWith(
        color: onSurface.withValues(alpha: 0.65),
      ),
      labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}
