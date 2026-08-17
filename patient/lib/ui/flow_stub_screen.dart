/// Placeholders for screens the flow routes through but which are not built yet.
///
/// # The spec id is traceability, not copy
///
/// Every stub still names the spec section it stands for — whoever builds the real screen needs to
/// know which copy and which fields belong to it. But it is carried as a [Key] rather than printed
/// in the app bar, because a patient reading "PROF-04" learns nothing and the app stops looking
/// like a product. `screenKey` is how a test still finds a screen by the section it implements.
///
/// Deliberately plain. A stub that looks finished gets left alone; one that plainly is not gets
/// replaced. Title, one line of body, one button — nothing else.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// The key a screen carries so it can be found by the spec section it implements.
///
/// Used by [FlowStubScreen] and by the real screens that graduated out of it, so a routing test
/// does not have to assert on user-facing copy — which changes for design reasons and would make
/// every wording tweak a failing routing test.
Key screenKey(String specId) => Key('screen:$specId');

class FlowStubScreen extends StatelessWidget {
  const FlowStubScreen({
    super.key,
    required this.specId,
    required this.title,
    required this.onNext,
    this.body,
    this.nextLabel = 'Next',
    this.secondaryLabel,
    this.onSecondary,
  });

  /// The spec's identifier, e.g. `WALK-02`. Carried as a key, never rendered.
  final String specId;

  final String title;
  final String? body;
  final String nextLabel;
  final VoidCallback? onNext;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: screenKey(specId),
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(TeraSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: TeraText.section,
                  fontWeight: FontWeight.w700,
                  color: TeraColors.ink,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: TeraSpacing.sm),
              Text(
                body ?? 'This part of Tera is not built yet.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: TeraText.body,
                  color: TeraColors.neutral700,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: TeraSpacing.xl),
              FilledButton(onPressed: onNext, child: Text(nextLabel)),
              if (secondaryLabel != null) ...[
                const SizedBox(height: TeraSpacing.sm),
                TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
