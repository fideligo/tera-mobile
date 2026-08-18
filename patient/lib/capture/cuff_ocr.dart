/// Reading a tensimeter display from a photograph — the suggestion side of cuff entry.
///
/// # What this is allowed to be
///
/// **A data-entry aid, and nothing else.** The output never reaches the API as a machine reading.
/// It pre-fills fields that a person then checks against the device in front of them and confirms,
/// and the record of what happened is that a human confirmed the numbers — which is why a reading
/// entered this way is still submitted as `manual_entry`.
///
/// That is not a workaround for the backend refusing `source = 'photograph'`; it is the same
/// reasoning the backend refuses it for. `photograph` would assert that the *system* read the
/// display and stands behind the value. Recognition gets digits off a seven-segment LCD at an
/// angle in whatever light the room has, and an 8 read as a 6 looks exactly as confident as an 8
/// read as an 8. Nothing here stands behind anything.
///
/// # On-device, and that is not an implementation detail
///
/// ML Kit's text recogniser runs locally. A cloud OCR call would send a photograph of a patient's
/// blood pressure to a third party, which is the one thing a health record cannot do casually — so
/// the image is read on the handset and discarded, and only the digits survive into the form.
library;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:meta/meta.dart';

import 'cuff_reading.dart';

/// Shown over any reading a machine suggested, however it was produced.
///
/// The wording changed when the extractor became real: it used to say no photograph was taken,
/// which is no longer true. What has not changed is the instruction, because it is the part that
/// matters — the numbers are a suggestion until the patient has looked at the cuff.
const String ocrSuggestionNotice =
    'Read from your photograph by this phone. Digits on a small display are easy to misread, so '
    'check these against your cuff and correct them before saving.';

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
  /// without asking: a confident misread of a seven-segment display is the failure this whole flow
  /// exists to catch.
  ///
  /// ML Kit reports no per-line confidence on Android, so this is derived from how the numbers
  /// were found — an explicit `120/80` is stronger evidence than three loose integers — and is
  /// labelled as a heuristic rather than presented as a probability.
  final double confidence;

  /// True when the numbers did not come from a real reading of a real photograph.
  ///
  /// False for everything [CameraCuffOcrExtractor] produces now. [MockCuffOcrExtractor] still sets
  /// it, and the confirmation screen still says so, because a placeholder shown without that label
  /// is fabricated data presented as real (invariant 9).
  final bool simulated;

  Map<String, dynamic> toJson() => {
    'sys': systolicMmhg,
    'dia': diastolicMmhg,
    'pulse': pulseBpm,
    'confidence': confidence,
  };
}

/// How a candidate pair was found, which is what [CuffOcrReading.confidence] is derived from.
enum OcrMatch {
  /// `120/80` or `120 / 80` — the two numbers are stated as a pair by the display itself.
  explicitPair(0.9),

  /// Two plausible numbers on separate lines, in the order a cuff prints them.
  stackedLines(0.75),

  /// Plausible integers picked out of everything recognised, largest first.
  looseDigits(0.55);

  const OcrMatch(this.confidence);

  final double confidence;
}

/// The recognised text, reduced to a systolic/diastolic pair — or null when it does not contain one.
///
/// Pure, and separated from the recogniser so the parsing can be tested against real display
/// layouts without a camera, a photograph or a platform channel. Every rule below is a shape a
/// tensimeter actually prints:
///
///   * `120/80`, which some monitors print literally;
///   * three stacked lines, SYS over DIA over PULSE, which most of them print;
///   * a scattering of digits with the labels lost, which is what recognition returns when the
///     display is at an angle.
///
/// It refuses rather than guesses. A pair that fails the plausibility bounds, or a systolic at or
/// below its diastolic, returns null and the caller falls back to typing — a suggestion the
/// patient has to correct is worse than no suggestion, because it anchors them to a wrong number.
CuffOcrReading? parseCuffText(String text) {
  final normalised = text.replaceAll(RegExp(r'[Oo]'), '0');

  // 1. An explicit pair, written as one token.
  //
  // **A failed explicit pair ends the parse rather than falling through.** The display said these
  // two numbers belong together and in this order; if that pair is impossible — a systolic below
  // its diastolic, a value out of bounds — the recognition is wrong, and the later rules would
  // happily reorder `82/128` into `128/82` and present it as a reading. Silently correcting a
  // machine's misreading of a medical device is the one thing this parser must not do.
  final pair = RegExp(r'(\d{2,3})\s*[/\\]\s*(\d{2,3})').firstMatch(normalised);
  if (pair != null) {
    return _readingFrom(
      int.parse(pair.group(1)!),
      int.parse(pair.group(2)!),
      _pulseNear(normalised, exclude: [pair.group(1)!, pair.group(2)!]),
      OcrMatch.explicitPair,
    );
  }

  final numbers = RegExp(r'\d{2,3}')
      .allMatches(normalised)
      .map((m) => int.parse(m.group(0)!))
      .toList();
  if (numbers.length < 2) return null;

  // 2. The stacked layout, in the order it is printed: systolic, then diastolic, then pulse.
  //
  // Only trusted when the candidate systolic is the largest plausible number recognised. A cuff
  // prints its systolic first *and* largest, so a first number that is not the largest means the
  // reading order was not preserved — the digits came back scattered — and treating them as
  // stacked takes the first two of a jumble. `82 71 128` is that case: read as stacked it yields
  // 82/71, which passes every other check and is wrong.
  final maxPlausible = numbers
      .where((n) => n >= diastolicMinMmhg && n <= systolicMaxMmhg)
      .fold<int?>(null, (a, b) => a == null || b > a ? b : a);
  for (var i = 0; i + 1 < numbers.length; i++) {
    if (numbers[i] != maxPlausible) continue;
    final reading = _readingFrom(
      numbers[i],
      numbers[i + 1],
      i + 2 < numbers.length ? numbers[i + 2] : null,
      OcrMatch.stackedLines,
    );
    if (reading != null) return reading;
  }

  // 3. Labels lost. The two largest plausible integers, systolic first — a cuff's systolic is
  //    always its largest printed number, and its diastolic the next.
  final plausible = numbers.where((n) => n >= diastolicMinMmhg && n <= systolicMaxMmhg).toList()
    ..sort((a, b) => b.compareTo(a));
  if (plausible.length >= 2) {
    return _readingFrom(plausible[0], plausible[1], null, OcrMatch.looseDigits);
  }

  return null;
}

/// A pulse, if one of the remaining numbers looks like one.
int? _pulseNear(String text, {required List<String> exclude}) {
  for (final match in RegExp(r'\d{2,3}').allMatches(text)) {
    final token = match.group(0)!;
    if (exclude.contains(token)) continue;
    final value = int.parse(token);
    if (value >= pulseMinBpm && value <= pulseMaxBpm) return value;
  }
  return null;
}

/// Build a reading, or null when the pair is not one.
CuffOcrReading? _readingFrom(int systolic, int diastolic, int? pulse, OcrMatch match) {
  if (systolic < systolicMinMmhg || systolic > systolicMaxMmhg) return null;
  if (diastolic < diastolicMinMmhg || diastolic > diastolicMaxMmhg) return null;
  // A systolic at or below its diastolic is the signature of a misread, and it is also what
  // `DraftCuffReading.validate` refuses — better to decline here than to pre-fill a form that
  // cannot be saved.
  if (systolic <= diastolic) return null;

  return CuffOcrReading(
    systolicMmhg: systolic,
    diastolicMmhg: diastolic,
    pulseBpm: (pulse != null && pulse >= pulseMinBpm && pulse <= pulseMaxBpm) ? pulse : null,
    confidence: match.confidence,
    simulated: false,
  );
}

abstract class CuffOcrExtractor {
  /// Produce a suggestion from whatever the caller captured.
  Future<CuffOcrReading> extract();
}

/// Photograph the display, read it on-device, and return what it says.
///
/// Failure has two shapes and they are different states, not one:
///
///   * [CuffOcrCancelled] — the patient backed out at the camera. Nothing happened.
///   * [CuffOcrUnreadable] — a photograph was taken and no plausible pair came out of it. The
///     caller drops to manual entry, which is the honest outcome: an unreadable display is a
///     common, ordinary event and not an error to apologise for.
class CameraCuffOcrExtractor implements CuffOcrExtractor {
  CameraCuffOcrExtractor({ImagePicker? picker, TextRecognizer? recognizer})
    : _picker = picker ?? ImagePicker(),
      _recognizer = recognizer ?? TextRecognizer(script: TextRecognitionScript.latin);

  final ImagePicker _picker;
  final TextRecognizer _recognizer;

  @override
  Future<CuffOcrReading> extract() async {
    final photo = await _picker.pickImage(
      source: ImageSource.camera,
      // Full resolution, unlike the 1600px cap this used to carry. Seven-segment digits at an
      // angle are exactly the case where downscaling costs a recognition, and the image is read
      // and discarded on the handset rather than uploaded, so the pixels cost nothing but time.
      imageQuality: 100,
    );
    if (photo == null) throw const CuffOcrCancelled();

    final RecognizedText recognised;
    try {
      recognised = await _recognizer.processImage(InputImage.fromFilePath(photo.path));
    } on Object catch (e) {
      throw CuffOcrUnreadable('The text recogniser could not run. $e');
    }

    final reading = parseCuffText(recognised.text);
    if (reading == null) {
      throw const CuffOcrUnreadable(
        'No blood-pressure numbers could be read from that photograph.',
      );
    }
    return reading;
  }

  /// Releases the native recogniser. The caller owns the extractor's lifetime.
  Future<void> dispose() => _recognizer.close();
}

/// Fixed output, for building and testing the confirmation UX without a camera.
///
/// **Deliberately not 120/80.** These are placeholder numbers a patient is asked to check against
/// the device in front of them, and the textbook-normal reading is the one value nobody checks —
/// it looks like the right answer, so it gets confirmed on sight.
const int mockOcrSystolic = 152;
const int mockOcrDiastolic = 96;
const int mockOcrPulse = 74;
const double mockOcrConfidence = 0.88;

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

/// The patient backed out of the camera. Distinct from a failure, because it is not one.
class CuffOcrCancelled implements Exception {
  const CuffOcrCancelled();

  @override
  String toString() => 'Camera cancelled';
}

/// A photograph was taken and no plausible reading came out of it.
class CuffOcrUnreadable implements Exception {
  const CuffOcrUnreadable(this.reason);

  final String reason;

  @override
  String toString() => reason;
}
