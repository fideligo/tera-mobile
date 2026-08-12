/// What a check accumulates on its way to submission.
///
/// Kept out of [CheckSession] on purpose. That file is the state machine and is pure — no capture
/// types, no API types, testable on its own. This is the luggage: it rides alongside in
/// [CheckArgs] and is read only at the end.
library;

import 'package:meta/meta.dart';

import '../capture/current_context.dart';
import '../signal/signal_pipeline.dart';

@immutable
class CheckPayload {
  const CheckPayload({
    this.context,
    this.signal,
    this.capturedAt,
    this.cuffReadingSaved = false,
  });

  /// CTX-01. Collected on both paths, before the fork.
  final CurrentContext? context;

  /// Sensor path: the pipeline's output. Per-beat intervals and quality, never a waveform.
  final SignalResult? signal;

  /// When the capture started, for `started_at`.
  final DateTime? capturedAt;

  /// BP-only path: the cuff reading was confirmed and already filed by `CuffReadingScreen`.
  final bool cuffReadingSaved;

  CheckPayload copyWith({
    CurrentContext? context,
    SignalResult? signal,
    DateTime? capturedAt,
    bool? cuffReadingSaved,
  }) => CheckPayload(
    context: context ?? this.context,
    signal: signal ?? this.signal,
    capturedAt: capturedAt ?? this.capturedAt,
    cuffReadingSaved: cuffReadingSaved ?? this.cuffReadingSaved,
  );
}
