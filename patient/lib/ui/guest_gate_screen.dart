/// Shown in place of History or Profile when a guest taps either tab.
///
/// Both screens need an account: History reads `/v1/history`, Profile reads and writes
/// `/v1/profile`, and a guest has no token to send with either request. Rather than let the
/// request fail and show a generic error, the tap is intercepted before it happens and the
/// patient is told the actual reason and given the one useful next step.
library;

import 'package:flutter/material.dart';

import '../routing/routes.dart';
import 'tokens.dart';

class GuestGateScreen extends StatelessWidget {
  const GuestGateScreen({super.key, required this.feature});

  /// 'History' or 'Profile' — named in the message so the patient knows which tap this answers.
  final String feature;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: TeraColors.page,
    appBar: AppBar(title: Text(feature)),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(TeraSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.lock_outline,
              size: 56,
              color: TeraColors.neutral400,
            ),
            const SizedBox(height: TeraSpacing.lg),
            Text(
              'Login to save and track your $feature',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: TeraText.section,
                fontWeight: FontWeight.w700,
                color: TeraColors.ink,
              ),
            ),
            const SizedBox(height: TeraSpacing.sm),
            const Text(
              'Browsing as a guest keeps nothing between sessions. Sign in or create an '
              'account to keep a record on your phone and in your account.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: TeraText.body,
                color: TeraColors.neutral700,
                height: 1.45,
              ),
            ),
            const SizedBox(height: TeraSpacing.xl),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: () => Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil(Routes.login, (r) => false),
                style: FilledButton.styleFrom(
                  backgroundColor: TeraColors.ink,
                  foregroundColor: TeraColors.paper,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(TeraRadius.button),
                  ),
                ),
                child: const Text('Go to Login'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
