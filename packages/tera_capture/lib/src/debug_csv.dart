/// CSV serialisation of a recording, for offline signal work.
///
/// **This is serialisation only. It retains nothing, writes nothing and sends nothing.** Pure
/// functions from a recording to a string. File IO, the developer flag that gates it, and the
/// decision to write at all all live in the applications, because those are the parts with
/// consequences.
///
/// The package boundary is unchanged. `tera_capture` still does no buffer retention, no filtering,
/// no event detection, no beat pairing and no quality gate; a CSV formatter is none of the five.
///
/// **This exists outside the clinical path and is a documented exception to it, not a repeal.**
/// The rule that no raw waveform is persisted or transmitted (invariant 2) is a property of the
/// clinical path: the API accepts one derived interval per beat and nothing deeper, and no code
/// here can change that. What this enables is a developer, on their own handset, keeping the raw
/// series long enough to develop the signal chain against it. The obligations that come with it —
/// own or teammate data only, never a patient; deleted after analysis; never uploaded anywhere —
/// are the caller's, and the callers state them at the point of use.
library;

import 'capture_controller.dart';
import 'models.dart';

/// Accelerometer samples, one row per sample.
///
/// Both delivery clocks are included alongside the sensor timestamp. Which base a handset is
/// really using is the question that invalidates every cross-stream figure when it is answered
/// wrongly, and it cannot be recovered later from a file that dropped the evidence.
String accelerometerCsv(CaptureRecording<AccelSample> recording) {
  final rows = StringBuffer(
    'timestamp_nanos,x_ms2,y_ms2,z_ms2,realtime_at_delivery_nanos,uptime_at_delivery_nanos\n',
  );
  for (final s in recording.samples) {
    rows.writeln(
      '${s.timestampNanos},${s.x},${s.y},${s.z},'
      '${s.realtimeAtDeliveryNanos},${s.uptimeAtDeliveryNanos}',
    );
  }
  return rows.toString();
}

/// Camera frames, one row per frame.
///
/// `roi_mean` is the PPG signal — a single mean per frame. The frames themselves do not exist by
/// this point: `tera_capture` reduces each to one number inside the platform layer and never
/// surfaces pixels, so there is no image data here to export even deliberately.
///
/// `frame_number` is kept so a gap in the sequence is visible as a gap rather than silently
/// closing up, which is what makes dropped frames detectable offline.
String framesCsv(CaptureRecording<FrameSample> recording) {
  final rows = StringBuffer(
    'frame_number,timestamp_nanos,roi_mean,processing_nanos,'
    'realtime_at_delivery_nanos,uptime_at_delivery_nanos\n',
  );
  for (final s in recording.samples) {
    rows.writeln(
      '${s.frameNumber},${s.timestampNanos},${s.roiMean},${s.processingNanos},'
      '${s.realtimeAtDeliveryNanos},${s.uptimeAtDeliveryNanos}',
    );
  }
  return rows.toString();
}
