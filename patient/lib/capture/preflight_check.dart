/// The pre-flight check: is this handset about to vibrate in the middle of a capture?
///
/// # Why a notification costs the whole minute
///
/// Seismocardiography reads the chest wall through the phone's accelerometer, at amplitudes
/// well under a tenth of a g. The vibration motor is on the same chassis and is orders of
/// magnitude louder than the signal, so an incoming message during a capture does not add noise
/// to the aortic-valve fiducial — it replaces it. There is no filter for this downstream: the
/// artefact is broadband, it lands in the same band as the signal, and the capture that contains
/// it looks like a capture of something.
///
/// # What can actually be read, and what cannot
///
/// The pre-flight asks the patient for Do Not Disturb, and then verifies the **ringer mode**,
/// which is not the same question. That gap is deliberate and worth stating plainly:
///
///   * A silent ringer is *sufficient*. No ringer, no notification vibration, whatever the
///     interruption filter is set to. It is also readable on every Android device without any
///     permission at all — `AudioManager.getRingerMode()` is not privileged.
///   * Do Not Disturb on its own is *not* sufficient. A DND policy that allows alarms still lets
///     an alarm vibrate the handset, and "priority only" still admits whatever the patient marked
///     as priority.
///   * The interruption filter cannot be read here anyway. `NotificationManager
///     .getCurrentInterruptionFilter()` returns `INTERRUPTION_FILTER_UNKNOWN` unless the app holds
///     notification-policy access, which is a Settings-level grant. Asking a patient to hand over
///     notification-policy access before they may take a blood-pressure reading is a worse trade
///     than asking them to flip the ringer to silent, and `sound_mode_advanced` exposes no getter
///     for it regardless.
///
/// So the screen instructs the stronger habit (DND) and gates on the condition it can verify and
/// that is on its own enough (silent). A patient who has DND on but a live ringer is asked to
/// silence it too, which costs one press and is strictly safer than what they had.
///
/// Nothing here prevents a set alarm from firing. Nothing can.
library;

import 'package:sound_mode_advanced/sound_mode_advanced.dart';

/// What the handset is about to do to a capture.
enum PreflightStatus {
  /// The ringer is silent. Notifications cannot vibrate the chassis.
  silenced,

  /// The ringer is live or on vibrate. A message arriving mid-capture will move the phone.
  mayVibrate,

  /// The state could not be read. Not a pass and not a failure — see [needsAcknowledgement].
  unreadable,
}

extension PreflightOutcome on PreflightStatus {
  /// Whether the capture may start on this reading alone.
  bool get mayProceed => this == PreflightStatus.silenced;

  /// Whether the patient must be asked to confirm it themselves.
  ///
  /// **Only when the read failed**, never as an escape from a reading that came back and said no.
  /// A bypass offered next to "your ringer is on" is not a safeguard, it is a button people press;
  /// a bypass offered when the app genuinely cannot tell is the only thing left that is not
  /// refusing a measurement over a platform the app failed to interrogate. iOS restricts this read
  /// outright, which is the case this branch exists for — this build is Android-only, but the gate
  /// must not become the reason a capture is impossible if that changes.
  bool get needsAcknowledgement => this == PreflightStatus.unreadable;
}

/// Maps a ringer reading onto the vibration question.
///
/// `vibrate` is a failure and not a partial pass — it is the mode that vibrates on *every*
/// notification, which is the loudest of the three for our purposes even though it is the quietest
/// for the patient.
PreflightStatus preflightStatusFor(RingerModeStatus ringer) => switch (ringer) {
  RingerModeStatus.silent => PreflightStatus.silenced,
  RingerModeStatus.vibrate => PreflightStatus.mayVibrate,
  RingerModeStatus.normal => PreflightStatus.mayVibrate,
  RingerModeStatus.unknown => PreflightStatus.unreadable,
};

/// Reads the handset's current ringer state.
///
/// Injectable so the screen can be driven in a test without a platform channel, and so the
/// unreadable branch can be exercised at all — it is the branch that decides whether a patient is
/// ever allowed to override the gate, and it must not be the one path nothing covers.
typedef RingerModeReader = Future<RingerModeStatus> Function();

/// The real reader. Never throws: a `MissingPluginException` on a platform without the channel is
/// an unreadable state, which the gate already has an answer for, and not a crash on the screen
/// before a measurement.
Future<RingerModeStatus> readRingerMode() async {
  try {
    return await SoundMode.ringerModeStatus;
  } on Object {
    return RingerModeStatus.unknown;
  }
}

/// Runs the check and returns what the capture screen should do about it.
Future<PreflightStatus> runPreflight({RingerModeReader? reader}) async {
  final read = reader ?? readRingerMode;
  return preflightStatusFor(await read());
}
