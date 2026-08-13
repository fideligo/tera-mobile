/// BPREF-01 — set the BP reference before a sensor check (PM spec section 12).
///
/// Reached only when [CheckFlow.needsBpReference] says so: no reference yet, the last one has
/// aged past [bpReferenceMaxAgeDays], or something forced a refresh. A sensor trend is read
/// against this number, so the default path requires it before capture — [Routes.checkBpInput]
/// is the real cuff-entry screen this leads to.
///
/// # The demo bypass
///
/// A hackathon judge does not carry a cuff. "Skip Calibration (Demo)" exists for exactly that
/// case: it skips straight to the pre-check with no reference set, and marks
/// [CheckPayload.uncalibratedDemo] so [InsightScreen] shows a standing warning instead of quietly
/// presenting an unreferenced trend as an ordinary one. Nothing about capture, submission or the
/// backend's own confidence gating changes — the flag only controls whether that warning is
/// shown atop whatever the deterministic engine decides.
library;

import 'package:flutter/material.dart';

import '../routing/app_router.dart';
import '../routing/check_payload.dart';
import '../routing/check_session.dart';
import '../routing/routes.dart';
import 'tokens.dart';

class BpReferenceScreen extends StatelessWidget {
  const BpReferenceScreen({
    super.key,
    required this.flow,
    required this.session,
    required this.payload,
  });

  final TeraFlow flow;
  final CheckSession session;
  final CheckPayload payload;

  Future<void> _skip(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TeraRadius.card)),
        backgroundColor: TeraColors.paper,
        title: const Text(
          'Skip calibration?',
          style: TextStyle(fontWeight: FontWeight.w700, color: TeraColors.ink),
        ),
        content: const Text(
          'Without a cuff reading, Tera has nothing to compare this check against. The result '
          'will be labelled as an uncalibrated estimate throughout, and cannot be read as a '
          'blood-pressure value.',
          style: TextStyle(color: TeraColors.ink, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: TeraColors.plum,
              foregroundColor: TeraColors.paper,
            ),
            child: const Text('Skip anyway'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    TeraFlow.advance(
      context,
      CheckFlow.afterBpReference(session),
      payload: payload.copyWith(uncalibratedDemo: true),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: TeraColors.page,
    appBar: AppBar(title: const Text('BPREF-01')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(TeraSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: TeraSpacing.lg),
            const Icon(Icons.monitor_heart_outlined, size: 56, color: TeraColors.brand),
            const SizedBox(height: TeraSpacing.lg),
            const Text(
              'Set your blood pressure reference',
              style: TextStyle(
                fontSize: TeraText.section,
                fontWeight: FontWeight.w700,
                color: TeraColors.ink,
              ),
            ),
            const SizedBox(height: TeraSpacing.sm),
            const Text(
              'Tera reads your phone check against a recent cuff reading — that reading is '
              'the only place a blood-pressure number ever comes from. Rest quietly for five '
              'minutes, then take one with a validated upper-arm cuff.',
              style: TextStyle(color: TeraColors.neutral700, height: 1.45),
            ),
            const SizedBox(height: TeraSpacing.xl),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pushReplacementNamed(
                  Routes.checkBpInput,
                  arguments: CheckArgs(session, payload),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: TeraColors.ink,
                  foregroundColor: TeraColors.paper,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(TeraRadius.button),
                  ),
                ),
                child: const Text('Add BP reading'),
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.all(TeraSpacing.md),
              decoration: systemFlagDecoration(),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, color: TeraColors.plum, size: 20),
                  const SizedBox(width: TeraSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'No cuff on hand?',
                          style: TextStyle(fontWeight: FontWeight.w700, color: TeraColors.ink),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'You can continue without one. The result will be marked as an '
                          'uncalibrated estimate and cannot be read as a blood-pressure value.',
                          style: TextStyle(color: TeraColors.ink, fontSize: TeraText.small, height: 1.4),
                        ),
                        const SizedBox(height: TeraSpacing.sm),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => _skip(context),
                            style: TextButton.styleFrom(foregroundColor: TeraColors.plum),
                            child: const Text('Skip calibration (demo)'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
