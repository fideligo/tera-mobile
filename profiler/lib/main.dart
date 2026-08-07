/// Tera device capability profiler.
///
/// One question: can this handset run Tera? It is not the patient app and must not grow into
/// one (BUILD_SPEC 6). It is a thin consumer of `package:tera_capture`, which holds all the
/// sensor and camera work and which the patient app will consume next.
library;

import 'package:flutter/material.dart';

import 'ui/profiler_page.dart';

void main() {
  runApp(const TeraProfilerApp());
}

class TeraProfilerApp extends StatelessWidget {
  const TeraProfilerApp({super.key});

  /// The Tera palette (BUILD_SPEC 5.1), reused here for consistency with the dashboard.
  ///
  /// The colour rule applies with equal force: **nothing here uses colour to say a measurement
  /// is good or bad.** A device verdict is the backend's judgement, not a hue — the profiler
  /// reports numbers and states plainly when a measurement failed.
  static const Color ink = Color(0xFF12304A);
  static const Color brand = Color(0xFF114B5F);
  static const Color muted = Color(0xFF456990);
  static const Color surface = Color(0xFFE4FDE1);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tera Profiler',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: brand,
          primary: brand,
          secondary: muted,
          surface: Colors.white,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: surface,
        appBarTheme: const AppBarTheme(
          backgroundColor: ink,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: brand,
            foregroundColor: Colors.white,
            shape: const RoundedRectangleBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: brand,
            side: const BorderSide(color: brand),
            shape: const RoundedRectangleBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
        ),
      ),
      home: const ProfilerPage(),
    );
  }
}
