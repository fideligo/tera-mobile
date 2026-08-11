/// Reading a tensimeter display from a photograph — the suggestion side of cuff entry.
///
/// # What this is allowed to be
///
/// **A data-entry aid, and nothing else.** The output of this file never reaches the API. It
/// pre-fills a field that a person then reads against the device in front of them and confirms.
/// The record of what happened is that a human confirmed the numbers, which is why a reading
/// entered this way is still submitted as `manual_entry`.
///
/// That is not a workaround for the backend refusing `source = 'photograph'` — it is the same
/// reasoning the backend refuses it for. `photograph` would assert that the *system* read the
/// display and stands behind the value. Nothing here stands behind anything.
///
/// # The extractor is a mock
///
/// [MockCuffOcrExtractor] returns a fixed reading after a delay. There is no model, no image, and
/// no camera. It exists so the confirmation UX can be built and judged before the real extractor
/// exists, and it is marked [CuffOcrReading.simulated] so no screen can show its numbers without
/// saying where they came from — invariant 9 applies to a placeholder as much as to a seeder.
///
/// Replacing it means implementing [CuffOcrExtractor] and leaving every other part of the flow
/// alone. The confirmation step is not the extractor's to skip.
library;

import 'package:meta/meta.dart';

/// Fixed output of the mock. Named rather than inlined so a test can assert the screen shows
/// exactly these and not something it rounded or reformatted on the way.
const int mockOcrSystolic = 152;
const int mockOcrDiastolic = 96;
const int mockOcrPulse = 74;
const double mockOcrConfidence = 0.88;

/// Shown wherever simulated numbers appear. Kept here so it cannot drift from the thing it
/// describes.
const String simulatedOcrNotice =
    'Simulated reading. No photograph was taken and nothing was read from a device — these '
    'numbers are placeholders while this feature is built. Check them against your cuff and '
    'correct them before saving.';

@immutable
class CuffOcrReading {
  const CuffOcrReading({
    required this.systolicMmhg,
    required this.diastolicMmhg,
    required this.confidence,
    required this.simulated,
    this.pulseBpm,
  });

  final int systolicMmhg;
  final int diastolicMmhg;
  final int? pulseBpm;

  /// How sure the extractor is, 0 to 1.
  ///
  /// **Displayed, never acted on.** There is deliberately no threshold above which the app saves
  /// without asking: a confident misread of a seven-segment display is the failure mode this
  /// whole flow exists to catch, and 8 read as 6 looks exactly as confident as 8 read as 8.
  final double confidence;

  /// True when the numbers did not come from a real device. Never false in this build.
  final bool simulated;

  Map<String, dynamic> toJson() => {
    'sys': systolicMmhg,
    'dia': diastolicMmhg,
    'pulse': pulseBpm,
    'confidence': confidence,
  };
}

abstract class CuffOcrExtractor {
  /// Produce a suggestion from whatever the caller captured.
  Future<CuffOcrReading> extract();
}

/// Stand-in until a real extractor lands. Returns [mockOcrSystolic] over [mockOcrDiastolic] after
/// a delay long enough for the UI's waiting state to be visible and judged.
class MockCuffOcrExtractor implements CuffOcrExtractor {
  const MockCuffOcrExtractor({this.delay = const Duration(seconds: 1)});

  final Duration delay;

  @override
  Future<CuffOcrReading> extract() async {
    await Future<void>.delayed(delay);
    return const CuffOcrReading(
      systolicMmhg: mockOcrSystolic,
      diastolicMmhg: mockOcrDiastolic,
      pulseBpm: mockOcrPulse,
      confidence: mockOcrConfidence,
      // Not a parameter. A mock that could claim not to be one is a mock that will.
      simulated: true,
    );
  }
}
