// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

abstract final class LegacyColors {
  static const background = Color(0xFF0B0D0F);
  static const card = Color(0xFF101317);
  static const key = Color(0xFF16191D);
  static const accent = Color(0xFFA8CF6A);
  static const primary = Color(0xFFE7E4DE);
  static const muted = Color(0xFF767E87);
  static const danger = Color(0xFFE2725B);
}

TextStyle plex({
  double size = 14,
  Color color = LegacyColors.primary,
  bool mono = false,
  FontWeight weight = FontWeight.normal,
}) => TextStyle(
  fontFamily: mono ? 'IBMPlexMono' : 'IBMPlexSans',
  fontSize: size,
  color: color,
  fontWeight: weight,
);

ThemeData legacyTheme() => ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: LegacyColors.background,
  colorScheme: ColorScheme.fromSeed(
    seedColor: LegacyColors.accent,
    brightness: Brightness.dark,
  ),
  textTheme: ThemeData.dark().textTheme.apply(
    fontFamily: 'IBMPlexSans',
    bodyColor: LegacyColors.primary,
  ),
  useMaterial3: true,
);

Widget legacyCard({
  required Widget child,
  EdgeInsets padding = const EdgeInsets.all(12),
}) => Container(
  padding: padding,
  decoration: BoxDecoration(
    color: LegacyColors.card,
    borderRadius: BorderRadius.circular(14),
  ),
  child: child,
);
