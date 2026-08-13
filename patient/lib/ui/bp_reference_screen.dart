/// BPREF-01 — the two-path choice before a sensor check (PM spec section 12).
///
/// Reached only when [CheckFlow.needsBpReference] says so: no reference yet, the last one has
/// aged past [bpReferenceMaxAgeDays], or something forced a refresh. A sensor trend is read
/// against this number.
///
/// # Path A — calibration with a tensimeter
///
/// "Add BP reading" leads to [Routes.checkBpInput], the real cuff-entry screen, for the mandatory
/// systolic/diastolic form. The spec asks for that reading taken *simultaneously* with the phone
/// check; this app's cuff entry has always been a step **before** capture rather than after it —
/// changing that ordering is a submission-pipeline change, not a copy change, and was out of
/// scope for a same-day pass. The instructions below say so plainly: take the cuff reading
/// immediately before starting the recording, while seated together, so the two are as close to
/// simultaneous as this flow allows.
///
/// # Path B — no-cuff demo bypass
///
/// A hackathon judge does not carry a cuff. "Skip calibration (demo)" exists for exactly that
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeraRadius.card),
        ),
        backgroundColor: TeraColors.paper,
        title: const Text(
          'Skip calibration?',
          style: TextStyle(fontWeight: FontWeight.w700, color: TeraColors.ink),
        ),
        content: const Text(
          'Without a tensimeter, this BP-related trend is an uncalibrated estimate. It will be '
          'labelled as such throughout this check, and cannot be read as a blood-pressure '
          'value.',
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
      child: ListView(
        padding: const EdgeInsets.all(TeraSpacing.lg),
        children: [
          const Icon(
            Icons.monitor_heart_outlined,
            size: 48,
            color: TeraColors.brand,
          ),
          const SizedBox(height: TeraSpacing.md),
          const Text(
            'Choose how to check today',
            style: TextStyle(
              fontSize: TeraText.section,
              fontWeight: FontWeight.w700,
              color: TeraColors.ink,
            ),
          ),
          const SizedBox(height: TeraSpacing.sm),
          const Text(
            'Tera reads your phone check against a cuff reading — that reading is the only '
            'place a blood-pressure number ever comes from. Choose one of the two paths below.',
            style: TextStyle(color: TeraColors.neutral700, height: 1.45),
          ),
          const SizedBox(height: TeraSpacing.xl),

          // Path A — calibration with a tensimeter.
          Container(
            padding: const EdgeInsets.all(TeraSpacing.md),
            decoration: panelDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PATH A · Calibrate with a tensimeter',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: TeraColors.ink,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Sit quietly with your tensimeter ready. Take a cuff reading immediately '
                  'before you record with Tera, then enter that systolic/diastolic reading — '
                  'this is what calibrates the result you get today.',
                  style: TextStyle(
                    color: TeraColors.ink,
                    height: 1.4,
                    fontSize: TeraText.small,
                  ),
                ),
                const SizedBox(height: TeraSpacing.md),
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
              ],
            ),
          ),
          const SizedBox(height: TeraSpacing.lg),

          // Path B — no-cuff demo bypass.
          Container(
            padding: const EdgeInsets.all(TeraSpacing.md),
            decoration: systemFlagDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: TeraColors.plum,
                      size: 20,
                    ),
                    SizedBox(width: TeraSpacing.sm),
                    Expanded(
                      child: Text(
                        'PATH B · No-cuff demo bypass',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: TeraColors.ink,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Record pulse transit time only, with no tensimeter. Without a tensimeter, '
                  'this BP-related trend is an uncalibrated estimate — that warning stays on '
                  'screen for the whole result, and nothing below it is a blood-pressure value.',
                  style: TextStyle(
                    color: TeraColors.ink,
                    fontSize: TeraText.small,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: TeraSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _skip(context),
                    style: TextButton.styleFrom(
                      foregroundColor: TeraColors.plum,
                    ),
                    child: const Text('Skip calibration (demo)'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
