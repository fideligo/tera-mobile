/// Everything this handset holds about one patient, and the one function that removes it.
///
/// # Why this exists
///
/// Signing out cleared the tokens and nothing else. `ApiClient.signOut` calls `_tokens.clear()`,
/// which removes four keys; the six stores below survived it untouched. The next person to sign in
/// on the same phone therefore inherited the previous patient's date of birth, sex, height,
/// weight, reported conditions, pregnancy and arrhythmia answers, medication list, device
/// eligibility, calibration anchor, and any capture left mid-flow — none of it visibly, all of it
/// readable by the screens that render a profile.
///
/// A phone is shared far more often than an account is. This is the difference between logging out
/// and appearing to.
///
/// # Why the list is here and not at the call site
///
/// It went stale silently. `DeviceProfileStore`'s own docstring has said "Cleared on sign-out with
/// the rest of the session" since it was written, and nothing has ever cleared it. A list of
/// stores maintained inside a UI method is a list nobody updates when a seventh store lands.
///
/// [teraSecureKeys] and [teraLocalFiles] are the registry, and `local_wipe_test.dart` reads every
/// file under `lib/` and fails when it finds a `tera.`-prefixed storage key or a `tera_*.json`
/// filename that is not named here. Adding a store without adding it to this file breaks the
/// build's tests rather than leaking on a handset a year later.
library;

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Every key written to [FlutterSecureStorage] by this app.
///
/// Grouped by the store that owns them, so a reader can tell what each one costs.
const List<String> teraSecureKeys = [
  // token_store.dart — the session itself.
  'tera.access_token',
  'tera.refresh_token',
  'tera.role',
  'tera.subject',

  // phr_profile.dart — ONB-01 and ONB-03. Date of birth, sex, height, weight, the reported
  // condition list, and the name the patient asked to be called.
  'tera.phr_profile',

  // app_flow_state.dart — device eligibility, how far onboarding got, and the BP-reference dates.
  'tera.app_flow',

  // context_intake.dart — ONB-02. Pregnancy, known arrhythmia, the medication list.
  'tera.context_intake',

  // session_context.dart — which device profile this handset registered as.
  'tera.device_profile_id.v2',

  // notification_service.dart — whether the daily reminder is on, and at what time. A reminder
  // left behind fires "Time for your Tera check" on the next person's lock screen.
  'tera.reminder',
];

/// Every file this app writes to the application-documents directory.
const List<String> teraLocalFiles = [
  // calibration_anchor.dart — the cuff reading a pending calibration will be anchored to.
  'tera_calibration_anchor.json',

  // pending_check_store.dart — a capture held across the camera intent. Derived intervals, not a
  // waveform, but they belong to whoever recorded them.
  'tera_pending_check.json',
];

/// Removes every trace of the signed-in patient from this device.
///
/// **Best effort, and never throws.** A store that cannot be reached must not stop the remaining
/// ones being cleared, and must not leave the caller stuck on a screen belonging to the account it
/// is trying to leave. Each removal is attempted independently for that reason: one failure costs
/// one store, not the wipe.
///
/// It does *not* revoke the refresh token — `ApiClient.signOut` does that, and this runs whether
/// or not that call reached the server. Local removal cannot be conditional on the network.
///
/// [cancelScheduledNotifications] is injected rather than imported so this file stays pure storage
/// and a test does not need a platform channel. Removing the stored preference is not enough on its
/// own: the reminder is scheduled with the *system*, and an unscheduled cancel leaves it firing
/// after the record it belongs to is gone.
Future<void> wipeLocalPatientData({
  FlutterSecureStorage? storage,
  Directory? documentsDirectory,
  Future<void> Function()? cancelScheduledNotifications,
}) async {
  final secure =
      storage ??
      const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      );

  for (final key in teraSecureKeys) {
    try {
      await secure.delete(key: key);
    } on Object {
      // Deliberately swallowed; see above.
    }
  }

  Directory? dir = documentsDirectory;
  if (dir == null) {
    try {
      dir = await getApplicationDocumentsDirectory();
    } on Object {
      // No documents directory reachable — the secure keys above are already gone, which is the
      // half that holds the health record.
      return;
    }
  }

  for (final name in teraLocalFiles) {
    try {
      final file = File('${dir.path}/$name');
      if (file.existsSync()) await file.delete();
    } on Object {
      // Deliberately swallowed; see above.
    }
  }

  if (cancelScheduledNotifications != null) {
    try {
      await cancelScheduledNotifications();
    } on Object {
      // Deliberately swallowed; see above.
    }
  }
}
