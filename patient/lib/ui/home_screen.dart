/// Signed-in landing screen.
///
/// The entry point to the flow: eligibility, then a capture session. Both arrive in M3; this
/// screen is what holds them together and carries sign-out.
library;

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import 'capture_screen.dart';
import 'cuff_reading_screen.dart';
import 'eligibility_screen.dart';
import 'session_result_screen.dart';
import 'tokens.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final subject = auth.session?.subject ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tera'),
        actions: [
          TextButton(
            onPressed: () => auth.signOut(),
            style: TextButton.styleFrom(foregroundColor: TeraColors.paper),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(TeraSpacing.md),
        children: [
          Text(
            'Signed in as $subject',
            style: const TextStyle(color: TeraColors.neutral700, fontSize: TeraText.small),
          ),
          const SizedBox(height: TeraSpacing.lg),
          const Text(
            'Spot check',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: TeraColors.ink),
          ),
          const SizedBox(height: TeraSpacing.sm),
          const Text(
            'A spot check records two signals at once for about a minute, then compares the '
            'result with your own usual range. It is not a blood-pressure reading.',
            style: TextStyle(color: TeraColors.ink, height: 1.5),
          ),
          const SizedBox(height: TeraSpacing.lg),
          FilledButton(
            onPressed: () => _startSpotCheck(context),
            child: const Text('Start a spot check'),
          ),

          const SizedBox(height: TeraSpacing.xl),
          const Divider(),
          const SizedBox(height: TeraSpacing.lg),

          const Text(
            'Cuff reading',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: TeraColors.ink),
          ),
          const SizedBox(height: TeraSpacing.sm),
          const Text(
            'Type in the numbers from your upper-arm cuff. These are the blood-pressure '
            'measurements your spot checks are compared against, so record them when your clinic '
            'asks.',
            style: TextStyle(color: TeraColors.ink, height: 1.5),
          ),
          const SizedBox(height: TeraSpacing.lg),
          OutlinedButton(
            onPressed: () => _recordCuffReading(context),
            child: const Text('Record a cuff reading'),
          ),
        ],
      ),
    );
  }

  void _recordCuffReading(BuildContext context) {
    final navigator = Navigator.of(context);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => CuffReadingScreen(
          api: auth.api,
          onDone: () => navigator.popUntil((route) => route.isFirst),
        ),
      ),
    );
  }

  /// Eligibility, then capture, then the terminal steps.
  ///
  /// Each step replaces the one before it, so the back button never lands a patient in the middle
  /// of a recording that has already finished, and 'Done' returns to this screen rather than
  /// unwinding through screens whose work is over.
  void _startSpotCheck(BuildContext context) {
    final navigator = Navigator.of(context);

    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => EligibilityScreen(
          onProceed: (eligibility) => navigator.pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => CaptureScreen(
                onComplete: (capture) => navigator.pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => SessionResultScreen(
                      api: auth.api,
                      capture: capture,
                      // The eligibility probe already measured this handset; carrying its result
                      // forward avoids repeating six seconds of measurement the patient watched.
                      eligibility: eligibility,
                      onDone: () => navigator.popUntil((route) => route.isFirst),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
