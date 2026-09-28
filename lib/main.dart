// SPDX-License-Identifier: GPL-3.0-or-later
//
// sdr_flutter entry point. For now the UI runs on the synthetic
// DemoRadioController; the integrator swaps in the DSP-isolate controller.

import 'package:flutter/material.dart';

import 'ui/demo_radio_controller.dart';
import 'ui/main_screen.dart';
import 'ui/radio_controller.dart';

void main() {
  runApp(SdrApp(controller: DemoRadioController()));
}

class SdrApp extends StatelessWidget {
  const SdrApp({super.key, required this.controller});

  final RadioController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SDR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF66E5FF), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        useMaterial3: true,
      ),
      home: MainScreen(controller: controller),
    );
  }
}
