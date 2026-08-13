import 'package:flutter/material.dart';
import '../routing/app_router.dart';
import '../routing/check_session.dart';
import '../routing/routes.dart';
import 'tokens.dart';

class CalibrationIntroScreen extends StatelessWidget {
  const CalibrationIntroScreen({
    super.key,
    required this.session,
    required this.payload,
  });

  final CheckSession session;
  final dynamic payload;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.paper,
      appBar: AppBar(
        title: const Text('Calibration', style: TextStyle(color: TeraColors.ink, fontSize: TeraText.section, fontWeight: FontWeight.bold)),
        backgroundColor: TeraColors.paper,
        elevation: 0,
        iconTheme: const IconThemeData(color: TeraColors.ink),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(TeraSpacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),
              const Icon(Icons.favorite_outline, size: 80, color: TeraColors.brand),
              const SizedBox(height: TeraSpacing.xl),
              const Text(
                'Please put on your tensimeter / blood pressure cuff.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TeraText.section,
                  fontWeight: FontWeight.w700,
                  color: TeraColors.ink,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: TeraSpacing.md),
              const Text(
                'Make sure the cuff is properly placed on your bare arm, and you are seated comfortably with your arm supported at heart level.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TeraText.body,
                  color: TeraColors.neutral700,
                  height: 1.5,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    // Proceed to camera phase (capture screen)
                    TeraFlow.advance(
                      context,
                      CheckStep(session.copyWith(state: CheckState.capture), Routes.checkCapture),
                      payload: payload,
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: TeraColors.ink,
                    foregroundColor: TeraColors.paper,
                    padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TeraRadius.button)),
                  ),
                  child: const Text('Done', style: TextStyle(fontSize: TeraText.body, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
