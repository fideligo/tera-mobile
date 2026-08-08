/// The CSV must be a faithful record, or it is worse than none.
///
/// This data exists to develop the signal chain against. A column that silently reorders, a
/// dropped frame that closes up, or a delivery clock that is not carried through would all
/// produce a file that looks usable and is not.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_capture/tera_capture.dart';

CaptureRecording<AccelSample> _accel() => CaptureRecording<AccelSample>(
  samples: [
    const AccelSample(
      timestampNanos: 1000,
      x: 0.5,
      y: -1.25,
      z: 9.81,
      realtimeAtDeliveryNanos: 1500,
      uptimeAtDeliveryNanos: 1400,
    ),
    const AccelSample(
      timestampNanos: 3000,
      x: 0.0,
      y: 0.0,
      z: 9.8,
      realtimeAtDeliveryNanos: 3500,
      uptimeAtDeliveryNanos: 3400,
    ),
  ],
  startedAt: DateTime.utc(2026, 8, 9),
  endedAt: DateTime.utc(2026, 8, 9, 0, 1),
);

CaptureRecording<FrameSample> _frames() => CaptureRecording<FrameSample>(
  samples: [
    const FrameSample(
      timestampNanos: 1000,
      roiMean: 120.5,
      processingNanos: 400,
      frameNumber: 0,
      realtimeAtDeliveryNanos: 1500,
      uptimeAtDeliveryNanos: 1400,
    ),
    // Frame 1 is missing on purpose: a drop must stay visible as a gap.
    const FrameSample(
      timestampNanos: 3000,
      roiMean: 121.0,
      processingNanos: 410,
      frameNumber: 2,
      realtimeAtDeliveryNanos: 3500,
      uptimeAtDeliveryNanos: 3400,
    ),
  ],
  startedAt: DateTime.utc(2026, 8, 9),
  endedAt: DateTime.utc(2026, 8, 9, 0, 1),
);

void main() {
  test('accelerometer rows carry the sensor clock and both delivery clocks', () {
    final lines = accelerometerCsv(_accel()).trim().split('\n');

    expect(
      lines.first,
      'timestamp_nanos,x_ms2,y_ms2,z_ms2,'
      'realtime_at_delivery_nanos,uptime_at_delivery_nanos',
    );
    expect(lines[1], '1000,0.5,-1.25,9.81,1500,1400');
    expect(lines.length, 3, reason: 'header plus one row per sample');
  });

  test('a dropped frame stays visible as a gap in frame_number', () {
    final lines = framesCsv(_frames()).trim().split('\n');

    expect(lines[1], startsWith('0,'));
    // Not '1,'. If the export renumbered rows, a dropped frame would vanish and the achieved
    // rate would look perfect offline.
    expect(lines[2], startsWith('2,'));
  });

  test('units are named in the header, so a column cannot be misread later', () {
    expect(accelerometerCsv(_accel()), contains('x_ms2'));
    expect(framesCsv(_frames()), contains('roi_mean'));
    expect(framesCsv(_frames()), contains('timestamp_nanos'));
  });

  test('an empty recording produces a header and nothing else', () {
    final empty = CaptureRecording<AccelSample>(
      samples: const [],
      startedAt: DateTime.utc(2026, 8, 9),
      endedAt: DateTime.utc(2026, 8, 9),
    );

    // A zero-row file that still names its columns is unambiguous. A zero-byte file is not.
    expect(accelerometerCsv(empty).trim().split('\n').length, 1);
  });
}
