/// The pipeline must never emit a number it did not derive.
///
/// The stub is gone: the chain is the ML team's `tera_ptt.py`, ported to Dart. That raises the
/// stakes rather than lowering them. A stub that rejected everything could not fabricate anything;
/// a real chain can, and a fabricated interval becomes a genuine trend in the backend and an
/// estimate on a patient's screen, indistinguishable downstream from a measured one.
///
/// Numerical fidelity against the Python lives in `ptt_reference_test.dart`. This file is about
/// what the pipeline is allowed to hand to the rest of the system.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_capture/tera_capture.dart';
import 'package:tera_patient/capture/capture_session.dart';
import 'package:tera_patient/signal/signal_pipeline.dart';
import 'package:tera_patient/ui/capture_screen.dart';

/// A clock check both streams agree on, which is the only state a capture may proceed from.
CrossStreamClockCheck _sharedClock() {
  ClockBasisVerification verified(String name) => ClockBasisVerification(
    streamName: name,
    observed: ObservedClockBasis.uptime,
    declaredSource: null,
    medianRealtimeLagMillis: 0,
    medianUptimeLagMillis: 0,
    clockSeparationMillis: 0,
    sampleCount: 100,
  );
  return CrossStreamClockCheck(
    camera: verified('camera'),
    accelerometer: verified('accelerometer'),
  );
}

CaptureResult _capture({
  required List<double> scg,
  required List<double> ppg,
  required double fsScg,
  required double fsPpg,
  CrossStreamClockCheck? clock,
}) {
  final accel = CaptureRecording<AccelSample>(
    samples: [
      for (int i = 0; i < scg.length; i++)
        AccelSample(
          timestampNanos: (i * 1e9 / fsScg).round(),
          x: 0,
          y: 0,
          z: scg[i],
          realtimeAtDeliveryNanos: (i * 1e9 / fsScg).round() + 1000,
          uptimeAtDeliveryNanos: (i * 1e9 / fsScg).round() + 1000,
        ),
    ],
    startedAt: DateTime.utc(2026, 8, 12),
    endedAt: DateTime.utc(2026, 8, 12, 0, 0, 30),
  );
  final frames = CaptureRecording<FrameSample>(
    samples: [
      for (int i = 0; i < ppg.length; i++)
        FrameSample(
          timestampNanos: (i * 1e9 / fsPpg).round(),
          roiMean: ppg[i],
          processingNanos: 500000,
          frameNumber: i,
          realtimeAtDeliveryNanos: (i * 1e9 / fsPpg).round() + 1000,
          uptimeAtDeliveryNanos: (i * 1e9 / fsPpg).round() + 1000,
        ),
    ],
    startedAt: DateTime.utc(2026, 8, 12),
    endedAt: DateTime.utc(2026, 8, 12, 0, 0, 30),
  );

  return CaptureResult(
    accelerometer: accel,
    frames: frames,
    clockBasis: clock ?? _sharedClock(),
    startedAt: DateTime.utc(2026, 8, 12),
  );
}

Map<String, dynamic> _referenceCase(String name) {
  final raw = jsonDecode(
    File('test/fixtures/ptt_reference_vectors.json').readAsStringSync(),
  ) as List;
  return raw.cast<Map<String, dynamic>>().firstWhere((c) => c['name'] == name);
}

CaptureResult _fromReference(String name, {CrossStreamClockCheck? clock}) {
  final c = _referenceCase(name);
  return _capture(
    scg: (c['scg'] as List).map((v) => (v as num).toDouble()).toList(),
    ppg: (c['ppg'] as List).map((v) => (v as num).toDouble()).toList(),
    fsScg: (c['fs_scg'] as num).toDouble(),
    fsPpg: (c['fs_ppg'] as num).toDouble(),
    clock: clock,
  );
}

/// A capture with no cardiac content at all.
CaptureResult _flatCapture() => _capture(
  scg: List<double>.filled(6000, 9.81),
  ppg: List<double>.filled(900, 120.0),
  fsScg: 200,
  fsPpg: 30,
);

void main() {
  group('a real capture produces real intervals', () {
    test('a clean seated capture is accepted', () async {
      final result = await const TeraSignalPipeline().process(_fromReference('clean_seated'));

      expect(result.accepted, isTrue, reason: result.rejectionReason?.wireValue);
      expect(result.rejectionReason, isNull);
      expect(result.pttMs, isNotEmpty);
      expect(result.nBeatsUsable, result.pttMs.length);
      expect(result.nBeatsUsable, lessThanOrEqualTo(result.nBeatsTotal));
    });

    test('every emitted interval is inside the plausible band', () async {
      final result = await const TeraSignalPipeline().process(_fromReference('clean_seated'));

      // The backend's identical gate rejects the whole session on one bad interval, so the
      // filtering happens here and nothing outside the band may reach it.
      for (final v in result.pttMs) {
        expect(v, inInclusiveRange(pttMinMs, pttMaxMs));
      }
    });

    test('the quality block is derived from the capture, not defaulted', () async {
      final result = await const TeraSignalPipeline().process(_fromReference('clean_seated'));

      expect(result.quality['accel_rate_hz'], closeTo(200.0, 2.0));
      expect(result.quality['camera_fps'], closeTo(30.0, 2.0));
      // Both now have a definition, so neither is pinned at its worst any more.
      expect(result.quality['snr_db'], greaterThan(0.0));
      expect(result.quality['motion_index'], lessThan(1.0));
    });
  });

  group('a capture that does not support a number yields none', () {
    test('motion is refused, and carries no intervals', () async {
      final result = await const TeraSignalPipeline().process(_fromReference('motion_corrupt'));

      expect(result.accepted, isFalse);
      expect(result.pttMs, isEmpty, reason: 'a fabricated interval becomes a real trend');
      expect(result.nBeatsUsable, 0);
      expect(result.rejectionReason, SignalRejection.excessiveMotion);
    });

    test('a capture too short to analyse is refused', () async {
      final result = await const TeraSignalPipeline().process(_fromReference('too_short'));

      expect(result.accepted, isFalse);
      expect(result.pttMs, isEmpty);
      expect(result.rejectionReason, SignalRejection.insufficientBeats);
    });

    test('a flat signal is refused rather than turned into beats', () async {
      final result = await const TeraSignalPipeline().process(_flatCapture());

      expect(result.accepted, isFalse);
      expect(result.pttMs, isEmpty);
      expect(result.nBeatsUsable, 0);
    });

    test('every rejection names something the device could not do', () async {
      for (final capture in [
        _fromReference('motion_corrupt'),
        _fromReference('too_short'),
        _flatCapture(),
      ]) {
        final result = await const TeraSignalPipeline().process(capture);

        expect(result.rejectionReason, isNotNull);
        // None of the reasons describes the patient. A rejected session says nothing about them.
        expect(
          result.rejectionReason,
          isNot(SignalRejection.signalProcessingUnavailable),
          reason: 'the chain exists now; that value means a fault, not a bad capture',
        );
      }
    });
  });

  group('the clock check is a precondition, not a correction', () {
    test('an unestablished basis is refused before any analysis', () async {
      final result = await const TeraSignalPipeline().process(
        _fromReference(
          'clean_seated',
          clock: const CrossStreamClockCheck(camera: null, accelerometer: null),
        ),
      );

      // Otherwise the two streams are offset by however long the handset has slept since boot,
      // and pairing them gives a confident nonsense figure that looks normal on every measure.
      expect(result.accepted, isFalse);
      expect(result.rejectionReason, SignalRejection.clockUnstable);
      expect(result.pttMs, isEmpty);
    });

    test('streams on different bases are refused, not reconciled', () async {
      ClockBasisVerification v(String name, ObservedClockBasis basis) => ClockBasisVerification(
        streamName: name,
        observed: basis,
        declaredSource: null,
        medianRealtimeLagMillis: 0,
        medianUptimeLagMillis: 0,
        clockSeparationMillis: 4200,
        sampleCount: 100,
      );

      final result = await const TeraSignalPipeline().process(
        _fromReference(
          'clean_seated',
          clock: CrossStreamClockCheck(
            camera: v('camera', ObservedClockBasis.realtime),
            accelerometer: v('accelerometer', ObservedClockBasis.uptime),
          ),
        ),
      );

      expect(result.accepted, isFalse);
      expect(result.rejectionReason, SignalRejection.clockUnstable);
    });
  });

  group('invariant 2 holds at the boundary', () {
    test('the emitted array never exceeds the API bound', () async {
      final result = await const TeraSignalPipeline().process(_fromReference('clean_seated'));

      expect(result.pttMs.length, lessThanOrEqualTo(maxPttArrayLength));
    });

    test('the result carries intervals and quality, and nothing waveform-shaped', () async {
      final result = await const TeraSignalPipeline().process(_fromReference('clean_seated'));

      // One derived interval per beat is the deepest granularity that may leave the handset.
      expect(result.quality.keys, everyElement(isNot(contains('series'))));
      expect(result.quality.keys, everyElement(isNot(contains('samples'))));
      expect(result.quality.keys, everyElement(isNot(contains('raw'))));
      expect(result.pttMs.length, lessThan(400));
    });
  });

  group('the quality block is what the API will accept', () {
    // `QualityMetrics` in `app/schemas/session.py` makes all five mandatory, bounds each, and sets
    // `extra="forbid"`. A missing key, a stray key or an out-of-range value is a 422 that costs
    // the whole session — so the contract is asserted here rather than discovered on a handset.
    final required = <String, (double, double)>{
      'accel_rate_hz': (0.0, 10000.0),
      'camera_fps': (0.0, 1000.0),
      'dropped_frame_pct': (0.0, 100.0),
      'snr_db': (-100.0, 100.0),
      'motion_index': (0.0, 1.0),
    };

    test('an accepted result carries every required figure, in range', () async {
      final result = await const TeraSignalPipeline().process(
        _fromReference('clean_seated'),
      );

      expect(result.accepted, isTrue, reason: result.rejectionReason?.wireValue);
      for (final entry in required.entries) {
        final value = result.quality[entry.key];
        expect(value, isA<double>(), reason: '${entry.key} is missing or not a float');
        expect(
          value as double,
          inInclusiveRange(entry.value.$1, entry.value.$2),
          reason: '${entry.key} is outside what the API accepts',
        );
      }
    });

    test('it carries nothing the schema would refuse', () async {
      final result = await const TeraSignalPipeline().process(
        _fromReference('clean_seated'),
      );

      final allowed = {...required.keys, 'clock_offset_ms'};
      expect(result.quality.keys, everyElement(isIn(allowed)));
    });

    test('a rate that could not be measured is refused, not defaulted', () async {
      // Two samples: too few for `RateStatistics.fromTimestamps`, which is one of the two cases
      // that used to be filled in with 50 Hz and 30 fps.
      final result = await const TeraSignalPipeline().process(
        _capture(scg: [9.8, 9.9], ppg: [120, 121], fsScg: 200, fsPpg: 30),
      );

      expect(result.accepted, isFalse);
      expect(result.pttMs, isEmpty);
      expect(
        result.quality['accel_rate_hz'],
        isNull,
        reason: 'an unmeasured rate must not be reported as a measured one',
      );
    });
  });

  test('a rejected result cannot be constructed without a reason', () {
    expect(
      () => SignalResult(
        accepted: false,
        pttMs: const [],
        nBeatsTotal: 0,
        nBeatsUsable: 0,
        quality: const {},
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('the model version no longer claims there is no signal chain', () {
    // Every stored row carries its own provenance. A row produced by the real chain must not be
    // labelled as one produced without it.
    expect(signalPipelineVersion, isNot(contains('nosignal')));
    expect(signalPipelineVersion, contains('ptt'));
  });
}
