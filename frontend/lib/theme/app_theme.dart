import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const _background = Color(0xFF101114);
  static const _surface = Color(0xFF1A1B20);
  static const _blue = Color(0xFF4D8DFF);
  static const _purple = Color(0xFF9B78FF);

  static final dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: _background,
    colorScheme: const ColorScheme.dark(
      primary: _blue,
      secondary: _purple,
      surface: _surface,
      onSurface: Color(0xFFF4F5F7),
    ),
    cardTheme: CardThemeData(
      color: _surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF303137)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: _blue,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
