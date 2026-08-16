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

import 'package:image_picker/image_picker.dart';
import 'package:meta/meta.dart';

/// Fixed output of the mock. Named rather than inlined so a test can assert the screen shows
/// exactly these and not something it rounded or reformatted on the way.
///
/// **Deliberately not 120/80.** These are placeholder numbers a patient is asked to check against
/// the device in front of them, and the textbook-normal reading is the one value nobody checks —
/// it looks like the right answer, so it gets confirmed on sight. A raised reading at a middling
/// confidence keeps the confirmation step doing its job. They were briefly 120/80 at 0.98 (commit
/// 0200c30, alongside several other unrelated changes) with no test updated to match; this is the
/// original intent restored.
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

/// Opens the camera, then returns the same fixed reading [MockCuffOcrExtractor] does.
///
/// **The photograph is taken and then discarded unread.** Nothing looks at those pixels: there is
/// no text recogniser behind this, and the numbers below are the same constants the pure mock
/// returns. It exists so the capture *gesture* can be demonstrated end to end — point the phone at
/// a monitor, take the shot, watch the fields populate — while the extraction behind it is still
/// unbuilt.
///
/// It is therefore still [CuffOcrReading.simulated], and the confirmation screen still shows
/// [simulatedOcrNotice] over the result. That matters more here than it did for the pure mock, not
/// less: having just photographed their own monitor, a patient has every reason to assume the
/// numbers came from the photograph. They did not, and the screen has to say so before they
/// confirm a reading into their clinical record.
///
/// Replacing this with a real extractor means reading `photo.path` and leaving the rest alone.
class CameraCuffOcrExtractor implements CuffOcrExtractor {
  const CameraCuffOcrExtractor({
    this.picker,
    this.processingDelay = const Duration(milliseconds: 1500),
  });

  final ImagePicker? picker;

  /// How long the "reading the display" state is held after the shutter.
  final Duration processingDelay;

  @override
  Future<CuffOcrReading> extract() async {
    final photo = await (picker ?? ImagePicker()).pickImage(
      source: ImageSource.camera,
      maxWidth: 1600,
    );
    if (photo == null) {
      // Cancelled at the camera. Not an error and not a reading — the caller returns to the
      // choice screen rather than pre-filling anything.
      throw const CuffOcrCancelled();
    }

    await Future<void>.delayed(processingDelay);
    return const CuffOcrReading(
      systolicMmhg: mockOcrSystolic,
      diastolicMmhg: mockOcrDiastolic,
      pulseBpm: mockOcrPulse,
      confidence: mockOcrConfidence,
      simulated: true,
    );
  }
}

/// The patient backed out of the camera. Distinct from a failure, because it is not one.
class CuffOcrCancelled implements Exception {
  const CuffOcrCancelled();

  @override
  String toString() => 'Camera cancelled';
}
