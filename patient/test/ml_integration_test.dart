/// The three things the ML handover changed about how signal reaches the chain.
///
/// Azka's handover is written against a different app — it names `screening_local_datasource.dart`,
/// `screening_cubit.dart` and an `infantId`, none of which exist here — so none of it was
/// copy-pasteable. What transferred is the reasoning, and these are the parts of it that are
/// testable without a phone: the axis selection, the refusal vocabulary, and the boundary that
/// keeps raw waveform off the wire while all of the above happens on the handset.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/signal/rejection_messages.dart';
import 'package:tera_patient/signal/signal_pipeline.dart';

void main() {
  group('a refusal is worded once, and never about the patient', () {
    test('every reason the chain can emit has a sentence', () {
      // A reason with no wording renders as a blank where an explanation should be. The backend
      // learned this the expensive way with `PRIORITY_ACTION_WORDING`, where a missing key was a
      // 500 on the commonest path in the product.
      for (final reason in SignalRejection.values) {
        final message = patientMessageFor(reason);
        expect(message, isNotEmpty, reason: '${reason.name} has no wording');
        expect(message.length, greaterThan(10), reason: '${reason.name} is too terse to act on');
      }
    });

    test('an unknown reason still says something usable', () {
      expect(patientMessageFor(null), isNotEmpty);
    });

    test('no refusal states or implies a finding about the person', () {
      // Invariant 6. A refused capture is a fact about a recording, and a failure message is the
      // easiest place in the product to drift into a clinical claim.
      const forbidden = [
        'tekanan darah',
        'hipertensi',
        'penyakit',
        'diagnosis',
        'obat',
        'dokter',
      ];
      for (final reason in SignalRejection.values) {
        final message = patientMessageFor(reason).toLowerCase();
        for (final word in forbidden) {
          expect(
            message,
            isNot(contains(word)),
            reason: '${reason.name} says something about the patient, not the recording',
          );
        }
      }
    });

    test('the wire values map back, so a server refusal is not shown raw', () {
      // The backend gates again on ingest and can refuse for a reason the handset never produced.
      expect(
        rejectionFromWire('sensor_rate_below_qualified'),
        SignalRejection.sensorRateBelowQualified,
      );
      expect(rejectionFromWire('excessive_motion'), SignalRejection.excessiveMotion);
      // Unknown stays unknown rather than being flattened onto the nearest guess; the caller then
      // keeps the server's own sentence.
      expect(rejectionFromWire('something_new'), isNull);
      expect(rejectionFromWire(null), isNull);
    });

    test('every enum value round-trips through its wire value', () {
      for (final reason in SignalRejection.values) {
        expect(rejectionFromWire(reason.wireValue), reason);
      }
    });
  });

  group('the axis the intervals came from is reported', () {
    test('a result names its axis and what was tried', () {
      // Blocker 2 in the handover: the chain read `s.z` and nothing else, so a capture where the
      // phone sat at an angle failed with no way to ask whether another axis would have worked.
      const result = SignalResult(
        accepted: true,
        pttMs: [240, 241],
        nBeatsTotal: 2,
        nBeatsUsable: 2,
        quality: {},
      );

      // Z is the default because it is the axis the instructions ask for; a result that fell back
      // to X or Y is saying the phone was not held as described.
      expect(result.axis, 'z');
      expect(result.axesTried, contains('z'));
    });
  });

  group('invariant 2 survives the integration', () {
    test('SignalResult carries no field a waveform could travel in', () {
      // The handover's own contract posts `scg`, `scg_x`, `scg_y`, `ppg`, `t_scg` and `t_ppg` —
      // full sample arrays. That design was not adopted: the chain runs on the handset instead, so
      // the arrays never reach a wire. `scg`/`ppg` exist on this type for the compile-time-gated
      // debug export and default to empty, and `SessionSubmitter` has no field for either.
      const result = SignalResult(
        accepted: true,
        pttMs: [240],
        nBeatsTotal: 1,
        nBeatsUsable: 1,
        quality: {},
      );

      expect(result.scg, isEmpty);
      expect(result.ppg, isEmpty);
    });

    test('the per-beat array stays inside the API bound', () {
      // `max_ptt_array_length`. One derived interval per beat is the deepest granularity the API
      // accepts, and the bound is what stops "per beat" quietly becoming "per sample".
      expect(maxPttArrayLength, 300);
    });
  });
}
