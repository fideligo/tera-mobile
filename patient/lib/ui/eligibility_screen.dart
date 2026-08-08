/// Device eligibility, shown before a patient is offered a capture.
///
/// A refusal here is a *system* state — the handset is not suitable — so it uses the
/// system-flag treatment. Nothing on this screen is about the patient's physiology, and no
/// colour is used to grade anything.
library;

import 'package:flutter/material.dart';

import '../capture/eligibility_check.dart';
import 'tokens.dart';

class EligibilityScreen extends StatefulWidget {
  const EligibilityScreen({super.key, required this.onProceed});

  final void Function(EligibilityResult) onProceed;

  @override
  State<EligibilityScreen> createState() => _EligibilityScreenState();
}

class _EligibilityScreenState extends State<EligibilityScreen> {
  final _checker = EligibilityChecker();
  EligibilityResult? _result;
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    final result = await _checker.check();
    if (mounted) {
      setState(() {
        _result = result;
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;

    return Scaffold(
      appBar: AppBar(title: const Text('Check this phone')),
      body: ListView(
        padding: const EdgeInsets.all(TeraSpacing.md),
        children: [
          const Text(
            'Tera needs a phone whose motion sensor is fast enough to time a heartbeat '
            'accurately. This takes a few seconds.',
            style: TextStyle(color: TeraColors.ink, height: 1.5),
          ),
          const SizedBox(height: TeraSpacing.lg),

          if (result == null) ...[
            FilledButton(
              onPressed: _running ? null : _run,
              child: Text(_running ? 'Checking…' : 'Check this phone'),
            ),
            if (_running) ...[
              const SizedBox(height: TeraSpacing.md),
              const LinearProgressIndicator(),
              const SizedBox(height: TeraSpacing.sm),
              const Text(
                'Hold the phone still.',
                style: TextStyle(color: TeraColors.muted, fontSize: 13),
              ),
            ],
          ] else ...[
            Container(
              decoration: result.canProceed ? panelDecoration() : systemFlagDecoration(),
              padding: const EdgeInsets.all(TeraSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.headline,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: TeraColors.ink,
                    ),
                  ),
                  const SizedBox(height: TeraSpacing.sm),
                  Text(result.detail, style: const TextStyle(color: TeraColors.ink, height: 1.5)),
                ],
              ),
            ),
            const SizedBox(height: TeraSpacing.lg),
            if (result.canProceed)
              FilledButton(
                onPressed: () => widget.onProceed(result),
                child: const Text('Start a spot check'),
              )
            else
              OutlinedButton(onPressed: _run, child: const Text('Check again')),
          ],
        ],
      ),
    );
  }
}
