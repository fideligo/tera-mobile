/// Bare-bones placeholders for screens the flow routes through but which are not built yet.
///
/// Deliberately ugly. A stub that looks finished gets left alone; one that plainly is not gets
/// replaced. Scaffold, title, one line of body, one button — nothing else.
///
/// Every stub names the spec section it stands for, so whoever builds the real screen knows which
/// copy and which fields belong to it without going back to ask.
library;

import 'package:flutter/material.dart';

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

  /// The spec's identifier, e.g. `WALK-02`. Shown on screen so a stub in a screenshot can be
  /// traced back to the section that defines it.
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
      appBar: AppBar(title: Text(specId)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(body ?? 'Not built yet. Routing only.'),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: onNext, child: Text(nextLabel)),
            if (secondaryLabel != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
