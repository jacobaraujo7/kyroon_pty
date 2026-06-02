import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Design tokens ported from kyroon_terminal's `theme.css`.
///
/// Dark Kyroon Enterprise palette + roxo (purple) product accent. Every color
/// used by the UI lives here so the look stays consistent — zero hard-coded
/// colors scattered across widgets.
class AppColors {
  AppColors._();

  // Surfaces / elevation
  static const bg = Color(0xFF0A0E16);
  static const surface = Color(0xFF0B1018);
  static const surfaceContainer = Color(0xFF0E1624);
  static const surfaceContainerHigh = Color(0xFF141C2A);
  static const surfaceHover = Color(0xFF1B2434);

  // Text
  static const fg = Color(0xFFE6ECF3);
  static const fgDim = Color(0xFFB0BDC9);
  static const fgMuted = Color(0xFF7A8694);

  // Accent (product) + states
  static const accent = Color(0xFF8B5CF6);
  static const accentStrong = Color(0xFF7C3AED);
  static const accentSoft = Color(0x1F8B5CF6);
  static const info = Color(0xFF4DA3FF);
  static const success = Color(0xFF22C55E);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);

  // Borders
  static const border = Color(0xFF1E2B3C);
  static const borderStrong = Color(0xFF2A3A4D);
}

/// Corner radii (AppRadius).
class AppRadius {
  AppRadius._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 22.0;
  static const full = 999.0;
}

/// Monospace stack. `CascadiaMono` is **bundled** as a font asset (see
/// pubspec.yaml), so it renders identically on web and desktop instead of
/// falling back to a system font that the web canvas can't load. The remaining
/// entries are fallbacks for glyphs Cascadia Mono lacks.
const kMonoFontFamily = 'CascadiaMono';
const kMonoFontFallback = <String>[
  'Cascadia Mono',
  'Cascadia Code',
  'Consolas',
  'Menlo',
  'Monaco',
  'Liberation Mono',
  'Courier New',
  'monospace',
];

/// The xterm terminal theme — mirrors `TerminalTab.tsx`'s xterm.js theme
/// (`#0d0d15` background, `#dee2e8` foreground, `#7c3aed` cursor) and fills in
/// a tasteful 16-color ANSI palette tuned for the dark surface.
const kTerminalTheme = TerminalTheme(
  cursor: Color(0xFF7C3AED),
  selection: Color(0x408B5CF6),
  foreground: Color(0xFFDEE2E8),
  background: Color(0xFF0D0D15),
  black: Color(0xFF1E2030),
  white: Color(0xFFDEE2E8),
  red: Color(0xFFEF4444),
  green: Color(0xFF22C55E),
  yellow: Color(0xFFF59E0B),
  blue: Color(0xFF4DA3FF),
  magenta: Color(0xFF8B5CF6),
  cyan: Color(0xFF14B8A6),
  brightBlack: Color(0xFF49506A),
  brightRed: Color(0xFFF87171),
  brightGreen: Color(0xFF4ADE80),
  brightYellow: Color(0xFFFBBF24),
  brightBlue: Color(0xFF7AB8FF),
  brightMagenta: Color(0xFFA78BFA),
  brightCyan: Color(0xFF2DD4BF),
  brightWhite: Color(0xFFF8FAFC),
  searchHitBackground: Color(0xFFF59E0B),
  searchHitBackgroundCurrent: Color(0xFF8B5CF6),
  searchHitForeground: Color(0xFF0D0D15),
);
