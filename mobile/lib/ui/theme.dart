import 'package:flutter/material.dart';

import 'tokens.dart';

/// The K2 · Bone theme.
///
/// Built from explicit [ColorScheme] constructors rather than
/// `ColorScheme.fromSeed`. Seeding derives a whole tonal palette from one
/// colour and cannot be made to land on specific hexes, which is why the app
/// previously looked like stock Material regardless of the seed.
///
/// Surfaces separate by **tone, not shadow**: elevation stays at zero, the
/// surface tint is transparent so Material's elevation overlay never shifts a
/// colour, and hairlines carry the separation.
ThemeData veritraLightTheme() => _buildTheme(Brightness.light);

ThemeData veritraDarkTheme() => _buildTheme(Brightness.dark);

const ColorScheme _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: BoneColors.darkAccent,
  onPrimary: BoneColors.darkOnAccent,
  primaryContainer: BoneColors.darkRaised,
  onPrimaryContainer: BoneColors.darkText,
  secondary: BoneColors.darkAccent,
  onSecondary: BoneColors.darkOnAccent,
  secondaryContainer: BoneColors.darkRaised,
  onSecondaryContainer: BoneColors.darkText,
  tertiary: BoneColors.darkAccent,
  onTertiary: BoneColors.darkOnAccent,
  tertiaryContainer: BoneColors.darkRaised,
  onTertiaryContainer: BoneColors.darkText,
  error: BoneColors.darkError,
  onError: BoneColors.darkOnError,
  errorContainer: BoneColors.darkErrorContainer,
  onErrorContainer: BoneColors.darkOnErrorContainer,
  surface: BoneColors.darkCanvas,
  onSurface: BoneColors.darkText,
  onSurfaceVariant: BoneColors.darkMuted,
  surfaceContainerLowest: BoneColors.darkCanvas,
  surfaceContainerLow: BoneColors.darkSurface,
  surfaceContainer: BoneColors.darkSurface,
  surfaceContainerHigh: BoneColors.darkRaised,
  surfaceContainerHighest: BoneColors.darkRaised,
  outline: BoneColors.darkOutline,
  outlineVariant: BoneColors.darkBorder,
  shadow: Color(0xff000000),
  scrim: Color(0xff000000),
  inverseSurface: BoneColors.darkAccent,
  onInverseSurface: BoneColors.darkOnAccent,
  inversePrimary: BoneColors.lightAccent,
  surfaceTint: Color(0x00000000),
);

const ColorScheme _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: BoneColors.lightAccent,
  onPrimary: BoneColors.lightOnAccent,
  primaryContainer: BoneColors.lightRaised,
  onPrimaryContainer: BoneColors.lightText,
  secondary: BoneColors.lightAccent,
  onSecondary: BoneColors.lightOnAccent,
  secondaryContainer: BoneColors.lightRaised,
  onSecondaryContainer: BoneColors.lightText,
  tertiary: BoneColors.lightAccent,
  onTertiary: BoneColors.lightOnAccent,
  tertiaryContainer: BoneColors.lightRaised,
  onTertiaryContainer: BoneColors.lightText,
  error: BoneColors.lightError,
  onError: BoneColors.lightOnError,
  errorContainer: BoneColors.lightErrorContainer,
  onErrorContainer: BoneColors.lightOnErrorContainer,
  surface: BoneColors.lightCanvas,
  onSurface: BoneColors.lightText,
  onSurfaceVariant: BoneColors.lightMuted,
  surfaceContainerLowest: BoneColors.lightSurface,
  surfaceContainerLow: BoneColors.lightSurface,
  surfaceContainer: BoneColors.lightRaised,
  surfaceContainerHigh: BoneColors.lightRaised,
  surfaceContainerHighest: BoneColors.lightRaised,
  outline: BoneColors.lightOutline,
  outlineVariant: BoneColors.lightBorder,
  shadow: Color(0xff000000),
  scrim: Color(0xff000000),
  inverseSurface: BoneColors.lightAccent,
  onInverseSurface: BoneColors.lightCanvas,
  inversePrimary: BoneColors.darkAccent,
  surfaceTint: Color(0x00000000),
);

/// Applies the ramp in [BoneType] to Material's slots.
///
/// Only seven styles are specified in `design/redesign.md`; the larger display
/// slots are scaled from `display` so nothing falls back to an unstyled
/// default. `labelSmall` is `micro`, which callers must uppercase themselves.
///
/// Colours are set per slot rather than through `TextTheme.apply`, because
/// `apply`'s `bodyColor` covers the label and body slots and would silently
/// overwrite the muted colour that `caption` and `micro` depend on.
TextTheme _textTheme(Color text, Color muted) {
  return TextTheme(
    displayLarge: BoneType.display.copyWith(
      fontSize: 34,
      letterSpacing: -1.02,
      color: text,
    ),
    displayMedium: BoneType.display.copyWith(
      fontSize: 30,
      letterSpacing: -0.9,
      color: text,
    ),
    displaySmall: BoneType.display.copyWith(color: text),
    headlineLarge: BoneType.display.copyWith(color: text),
    headlineMedium: BoneType.display.copyWith(
      fontSize: 22,
      letterSpacing: -0.66,
      color: text,
    ),
    headlineSmall: BoneType.display.copyWith(
      fontSize: 20,
      letterSpacing: -0.6,
      color: text,
    ),
    titleLarge: BoneType.title.copyWith(color: text),
    titleMedium: BoneType.title.copyWith(color: text),
    titleSmall: BoneType.label.copyWith(color: text),
    bodyLarge: BoneType.body.copyWith(color: text),
    bodyMedium: BoneType.body.copyWith(color: text),
    bodySmall: BoneType.caption.copyWith(color: muted),
    labelLarge: BoneType.label.copyWith(color: text),
    labelMedium: BoneType.label.copyWith(color: text),
    labelSmall: BoneType.micro.copyWith(color: muted),
  );
}

ThemeData _buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = isDark ? _darkScheme : _lightScheme;
  final stateColors =
      isDark ? VeritraStateColors.dark : VeritraStateColors.light;
  final textTheme = _textTheme(scheme.onSurface, scheme.onSurfaceVariant);
  // Brightness is intentionally not passed: it is already carried by the
  // scheme, and supplying both risks disagreeing with it.
  final base = ThemeData(colorScheme: scheme, textTheme: textTheme);

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    extensions: <ThemeExtension<dynamic>>[stateColors],
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      hintStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BoneRadii.md),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BoneRadii.md),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BoneRadii.md),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(BoneRadii.md),
        borderSide: BorderSide(color: scheme.error),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, BoneSpacing.minTapTarget),
        textStyle: textTheme.labelLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BoneRadii.md),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, BoneSpacing.minTapTarget),
        textStyle: textTheme.labelLarge,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BoneRadii.md),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, BoneSpacing.minTapTarget),
        textStyle: textTheme.labelLarge,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BoneRadii.lg),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      margin: EdgeInsets.zero,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: textTheme.labelSmall,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BoneRadii.pill),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BoneRadii.md),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BoneRadii.lg),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primary,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStatePropertyAll<TextStyle?>(
        textTheme.labelSmall,
      ),
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: textTheme.labelLarge,
      subtitleTextStyle: textTheme.bodySmall,
      iconColor: scheme.onSurfaceVariant,
      minVerticalPadding: BoneSpacing.md,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      space: 1,
      thickness: 1,
    ),
  );
}
