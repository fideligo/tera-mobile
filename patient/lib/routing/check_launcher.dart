/// Starting a check, from wherever it is started.
///
/// # Why this is not a method on HomeScreen any more
///
/// It was, and Profile grew its own shortcut instead: "Calibrate with a cuff" opened
/// `CuffReadingScreen` directly. That files a cuff reading and nothing else — **which cannot
/// produce a calibration.** A calibration is a pairing. `POST /v1/calibrations` takes a
/// `reference_cuff_reading_id` *and* `session_ids`, and the server derives `baseline_mean_ms` from
/// those sessions' own PTT; a cuff reading with no capture beside it has no baseline to anchor, so
/// the estimate model has nothing to compute against (`services/pressure_estimate.py` returns
/// `None` when `baseline_ptt_ms` is missing). The button looked like it calibrated and did not.
///
/// So there is one launcher, and both entry points use it.
///
/// # Invariant 8 is why this is a function and not a route argument
///
/// A check begins with symptom triage, always, before anything else is offered. A patient
/// reporting chest pain must not be walked through a pre-check or a cuff screen first. Any new
/// place that starts a check has to go through here to inherit that, and putting the triage push
/// inside the launcher is what makes forgetting it impossible rather than merely discouraged.
library;

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../capture/check_session_client.dart';
import '../capture/session_context.dart';
import '../ui/symptom_triage_screen.dart';
import 'app_router.dart';
import 'check_payload.dart';
import 'routes.dart';

/// Push symptom triage, and on the far side of it start a check.
///
/// [forceCalibration] makes this a calibration run whatever the server's history says: the capture
/// is taken and the cuff reading is collected against it, which is the only sequence that produces
/// a calibration the estimate model can use. Profile's "Recalibrate" passes it; Home's spot check
/// does not, and asks the record instead.
Future<void> launchCheck(
  BuildContext context, {
  required TeraFlow flow,
  required AuthController auth,
  bool forceCalibration = false,
}) async {
  final navigator = Navigator.of(context);

  await navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => SymptomTriageScreen(
        api: auth.api,
        onDone: () => navigator.popUntil((route) => route.isFirst),
        onProceed: () async {
          // **First-time calibration is decided by the record, not by local state.**
          //
          // `BpReferenceStatus` lives in this install's storage, so a reinstall or a second
          // handset would walk a patient with months of history back through first-time
          // calibration, and a cleared server account would skip it for someone who has never
          // calibrated. The server's own count is the only thing that answers "has this person
          // ever recorded a reading".
          //
          // Unreachable is treated as "not first time": the calibration path needs the network
          // anyway to be worth anything, and sending someone down it on a failed request would be
          // the worse of the two guesses.
          var needsCalibration = forceCalibration;
          if (!needsCalibration && auth.isSignedIn) {
            try {
              // `type=cuff_reading`, not every entry. "Has this person ever calibrated" is a
              // question about cuff readings specifically; asking for any history at all counted
              // a rejected capture as evidence of calibration.
              final history = await auth.api.getJson(
                '/v1/history?range=all&type=cuff_reading&limit=1',
              );
              final entries = history['entries'] as List<dynamic>? ?? [];
              needsCalibration = entries.isEmpty;
            } on Object {
              needsCalibration = false;
            }
          }

          final step = flow.startCheck();

          // Opened before the first screen that collects anything, so PRE-01 and CTX-01 have
          // somewhere to go in both modes.
          String? checkSessionId;
          try {
            final resolved = await SessionContextResolver(
              api: auth.api,
            ).resolveEpisode();
            checkSessionId = await CheckSessionClient(
              api: auth.api,
            ).open(episodeId: resolved.episodeId, mode: step.session.mode);
          } on Object {
            // Most often the contraindication gate at the door, or no network. The flow still
            // runs and the answers are still collected locally; they simply have nothing to
            // attach to, which the processing screen reports.
          }

          navigator.pushReplacementNamed(
            // A calibration run opens on the cuff intro, which explains recording with a cuff
            // alongside the phone before handing over to the same flow. Everything else goes
            // straight into the check the state machine chose.
            needsCalibration ? Routes.checkCalibrationIntro : step.route,
            arguments: CheckArgs(
              step.session,
              CheckPayload(
                checkSessionId: checkSessionId,
                firstTimeCalibration: needsCalibration,
              ),
            ),
          );
        },
      ),
    ),
  );
}
