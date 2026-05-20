import 'package:flutter/material.dart';

abstract final class C {
  // Backgrounds
  static const bg         = Color(0xFF080C09);
  static const bgPanel    = Color(0xFF0C1410);
  static const bgSelected = Color(0xFF0F2018);
  static const bgHeader   = Color(0xFF0A1A0D);

  // Borders
  static const border     = Color(0xFF1A3A22);
  static const borderHi   = Color(0xFF2A6B3A);

  // Text
  static const textHi     = Color(0xFF39FF14);  // neon green — primary
  static const text       = Color(0xFF22BB33);  // mid green
  static const textDim    = Color(0xFF0F6622);  // dim green
  static const textMuted  = Color(0xFF0A3315);  // barely visible

  // Semantic
  static const good       = Color(0xFF39FF14);
  static const warn       = Color(0xFFFFAA00);
  static const danger     = Color(0xFFFF3333);
  static const accent     = Color(0xFF00FFCC);  // cyan-green

  // Bar fill colours
  static const barLow     = Color(0xFF0A5522);
  static const barMid     = Color(0xFF1A9933);
  static const barHi      = Color(0xFF39FF14);
  static const barWarn    = Color(0xFFCC7700);
  static const barDanger  = Color(0xFFAA2200);
  static const barBg      = Color(0xFF0A1A0D);
}

abstract final class T {
  static const _mono = 'monospace';

  static const header = TextStyle(
    fontFamily: _mono,
    fontSize: 13,
    fontWeight: FontWeight.bold,
    color: C.textHi,
    letterSpacing: 1.5,
  );

  static const label = TextStyle(
    fontFamily: _mono,
    fontSize: 12,
    color: C.text,
  );

  static const labelDim = TextStyle(
    fontFamily: _mono,
    fontSize: 12,
    color: C.textDim,
  );

  static const value = TextStyle(
    fontFamily: _mono,
    fontSize: 12,
    fontWeight: FontWeight.bold,
    color: C.textHi,
  );

  static const muted = TextStyle(
    fontFamily: _mono,
    fontSize: 11,
    color: C.textMuted,
  );

  static const status = TextStyle(
    fontFamily: _mono,
    fontSize: 11,
    color: C.text,
  );

  static const title = TextStyle(
    fontFamily: _mono,
    fontSize: 14,
    fontWeight: FontWeight.bold,
    color: C.accent,
    letterSpacing: 2,
  );
}

ThemeData buildTheme() => ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: C.bg,
  colorScheme: const ColorScheme.dark(
    surface: C.bgPanel,
    primary: C.textHi,
    secondary: C.accent,
    error: C.danger,
  ),
  fontFamily: 'monospace',
  useMaterial3: false,
);
