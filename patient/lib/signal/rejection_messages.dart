/// What a patient is told when the signal chain declines to produce a number.
///
/// # Why this is one file and not a string beside each dialog
///
/// A refusal reaches a person in three places — the capture screen's abort, the retry dialog after
/// a completed minute, and the exported report — and they were saying different things about the
/// same `SignalRejection`. One table means a reason is worded once, and adding a value to the enum
/// without wording it is a compile error rather than a blank space on someone's screen.
///
/// # Two properties every string here has to keep
///
/// **Each names something the device or the recording could not do, never the patient.** A refused
/// capture is not a finding. "Your signal was poor" invites someone to wonder what is wrong with
/// them; "the recording was not clear enough" is both true and about the right subject.
///
/// **None of them is advice.** Invariant 6 forbids a diagnosis or a clinical instruction, and a
/// failure message is the easiest place to drift into one — "you may be unwell" is a sentence a
/// refusal must never produce. Every line below says what to do with Tera and nothing about health.
library;

import 'signal_pipeline.dart';

/// A refusal, in the patient's language.
///
/// Indonesian, matching the wording supplied for the motion abort and the noisy-signal case. The
/// rest of the app's interface is English; that inconsistency is recorded in `docs/decisions.md`
/// rather than resolved here, because which language the product speaks is a product decision.
String patientMessageFor(SignalRejection? reason) => switch (reason) {
  SignalRejection.poorSignalQuality =>
    'Sinyal terlalu berisik, mohon ulangi perekaman di tempat yang lebih tenang',
  SignalRejection.excessiveMotion => 'Jari bergerak, mohon ulang perekaman',
  SignalRejection.insufficientBeats =>
    'Denyut yang terbaca belum cukup. Mohon ulangi dengan jari menutup penuh kamera',
  SignalRejection.postureUnstable =>
    'Posisi tubuh belum stabil. Duduk bersandar, lalu ulangi perekaman',
  SignalRejection.torchUnavailable =>
    'Lampu kamera tidak menyala. Periksa izin kamera, lalu ulangi perekaman',
  SignalRejection.sensorRateBelowQualified =>
    'Sensor gerak ponsel ini terlalu lambat untuk perekaman yang dapat diandalkan',
  SignalRejection.clockUnstable =>
    'Waktu sensor tidak sinkron. Tutup aplikasi lain, lalu ulangi perekaman',
  SignalRejection.userAborted => 'Perekaman dihentikan',
  SignalRejection.signalProcessingUnavailable =>
    'Analisis tidak dapat diselesaikan pada perekaman ini. Mohon ulangi',
  // A reason the handset does not know is a reason the *server* refused for, and its own sentence
  // is better than a guess made here. The caller passes it through; this is the last resort.
  null => 'Perekaman belum bisa dipakai. Mohon ulangi',
};

/// The wire values the backend may send back that the handset has no enum for.
///
/// `SignalRejection` mirrors the backend's `rejection_reason`, but the backend gates a session
/// again on ingest — the plausibility check and the achieved-rate check both run there — and it
/// can refuse for a reason this build has never produced locally. Rather than showing a raw wire
/// value like `sensor_rate_below_qualified` to a patient, it is mapped back through the enum.
///
/// Returns null when the value is genuinely unknown, so the caller can fall back to the server's
/// own sentence instead of inventing one.
SignalRejection? rejectionFromWire(String? wireValue) {
  if (wireValue == null) return null;
  for (final reason in SignalRejection.values) {
    if (reason.wireValue == wireValue) return reason;
  }
  return null;
}
