import 'package:flutter/material.dart';
import 'tokens.dart';

class SignalAcceptedScreen extends StatefulWidget {
  final VoidCallback onNext;
  const SignalAcceptedScreen({super.key, required this.onNext});

  @override
  State<SignalAcceptedScreen> createState() => _SignalAcceptedScreenState();
}

class _SignalAcceptedScreenState extends State<SignalAcceptedScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 2), widget.onNext);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(TeraSpacing.xxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.check_circle_outline,
                color: TeraColors.brand,
                size: 80,
              ),
              const SizedBox(height: TeraSpacing.xl),
              const Text(
                'Session accepted',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TeraText.section,
                  fontWeight: FontWeight.bold,
                  color: TeraColors.ink,
                ),
              ),
              const SizedBox(height: TeraSpacing.md),
              const Text(
                'Signal quality was good. Loading your results...',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TeraText.body,
                  color: TeraColors.neutral700,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SignalAdjustScreen extends StatelessWidget {
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final int attemptCount;
  final int maxAttempts;

  const SignalAdjustScreen({
    super.key,
    required this.onRetry,
    required this.onCancel,
    required this.attemptCount,
    required this.maxAttempts,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(TeraSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.compare_arrows,
                color: TeraColors.neutral500,
                size: 80,
              ),
              const SizedBox(height: TeraSpacing.xl),
              const Text(
                'Let\'s adjust your position',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TeraText.section,
                  fontWeight: FontWeight.bold,
                  color: TeraColors.ink,
                ),
              ),
              const SizedBox(height: TeraSpacing.md),
              const Text(
                'Move your finger to fully cover the camera and flash.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TeraText.body,
                  color: TeraColors.neutral700,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: TeraSpacing.xl),
              Text(
                'Attempt $attemptCount of $maxAttempts',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: TeraText.small,
                  color: TeraColors.neutral500,
                ),
              ),
              const SizedBox(height: TeraSpacing.xxl),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  backgroundColor: TeraColors.ink,
                  padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(TeraRadius.button),
                  ),
                ),
                child: const Text(
                  'Try again',
                  style: TextStyle(
                    fontSize: TeraText.body,
                    color: TeraColors.paper,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: TeraSpacing.md),
              TextButton(
                onPressed: onCancel,
                child: const Text(
                  'Back to home',
                  style: TextStyle(
                    fontSize: TeraText.body,
                    color: TeraColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SignalRepeatedFailureScreen extends StatelessWidget {
  final VoidCallback onDone;

  const SignalRepeatedFailureScreen({super.key, required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(TeraSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.error_outline,
                color: TeraColors.neutral500,
                size: 80,
              ),
              const SizedBox(height: TeraSpacing.xl),
              const Text(
                'A few sessions haven\'t come through clearly',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TeraText.section,
                  fontWeight: FontWeight.bold,
                  color: TeraColors.ink,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: TeraSpacing.md),
              const Text(
                'Your reading can drift when you\'re tense. A short rest often helps.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TeraText.body,
                  color: TeraColors.neutral700,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: TeraSpacing.md),
              const Text(
                'Try again when you\'re ready, or take a break and come back later — your streak stays intact.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TeraText.body,
                  color: TeraColors.neutral500,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: TeraSpacing.xxl),
              FilledButton(
                onPressed: onDone,
                style: FilledButton.styleFrom(
                  backgroundColor: TeraColors.ink,
                  padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(TeraRadius.button),
                  ),
                ),
                child: const Text(
                  'Take a break',
                  style: TextStyle(
                    fontSize: TeraText.body,
                    color: TeraColors.paper,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
