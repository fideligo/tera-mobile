/// What a single camera frame is allowed to say about whether the capture should continue.
///
/// # Why this is a file and not two constants in the capture screen
///
/// These two rules abort a minute the patient has already sat through, and both had to be
/// retuned after real hardware disagreed with them. Tuning figures that expensive belong
/// somewhere they can be read, argued with and tested without a camera — the screen that used to
/// hold them needs a `CameraImage` to exercise any of this.
///
/// Neither rule is a quality gate. They decide whether the *finger is still on the lens*, which
/// is a fact about the recording session and not about the signal; the quality gate lives in
/// `signal/signal_pipeline.dart` and runs on what these let through.
library;

/// How far the red channel may fall below the locked baseline before the finger is treated as
/// having left the lens.
///
/// **A fraction of the baseline, not an absolute level, and that is the correction.** This was
/// 28, in 0-255 units. What 28 *means* depends entirely on the handset: against a baseline of 210
/// it is a 13% departure, which a single routine auto-exposure step clears on its own; against a
/// baseline of 60 it is 47%, which nothing short of the finger lifting produces. One constant
/// cannot be both, so it was simultaneously aborting still patients on bright sensors and unable
/// to notice a genuine lift on dark ones. Scaling to the baseline removes the handset from the
/// question.
///
/// 0.45 sits far above anything the measurement itself does — the pulsatile component of a
/// fingertip PPG is on the order of 1-2% of the DC level, and an auto-exposure or auto-white-
/// balance step is at worst a few tens of percent — and far below what a lens losing its finger
/// does, which is most of the way to ambient.
const double fingerLiftRedDropFraction = 0.45;

/// Consecutive frames past that threshold before the capture is abandoned.
///
/// **Not one, deliberately, and this has already been corrected once.** The earlier check aborted
/// on a single dark frame: one auto-exposure adjustment, one late-delivered buffered frame or one
/// frame caught while the torch was still ramping was enough to discard the whole capture. At
/// roughly 30 fps ten frames is about a third of a second — indistinguishable from immediate to a
/// person, and immune to any single bad frame or short burst of them.
const int fingerLiftFrameCount = 10;

/// Below this mean luma the lens is treated as uncovered, whatever the red channel says.
///
/// A fingertip against the lens with the torch on reads far brighter than this; an uncovered lens
/// in a lit room reads far darker.
const int uncoveredLensLumaThreshold = 50;

/// Consecutive dark frames before the recording is stopped — about half a second at 30 fps.
const int uncoveredLensFrameCount = 15;

/// Whether this frame's red level says the finger has left the lens.
///
/// **Asymmetric: only a fall counts.** A rise above the baseline is not something a finger leaving
/// the lens produces — it is the exposure pipeline deciding the field is too dark and opening up,
/// or the torch finishing its ramp. Treating a rise as movement meant the camera's own gain
/// control could abort a capture in which the patient never moved, which is the false positive
/// this rule exists to have stopped causing.
bool fingerHasLeftLens({required double red, required double baselineRed}) {
  if (baselineRed <= 0) return false;
  return red < baselineRed * (1 - fingerLiftRedDropFraction);
}

/// Whether this frame reads as an uncovered lens.
bool lensReadsUncovered(double meanLuma) =>
    meanLuma < uncoveredLensLumaThreshold;
