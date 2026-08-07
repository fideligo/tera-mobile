/// A measurement that either succeeded or explicitly failed.
///
/// BUILD_SPEC 6.2: "**Report measured values only.** If a measurement fails, say so — never
/// substitute an estimate or a plausible-looking number." Invariant 9 says the same thing more
/// broadly.
///
/// This type is how that rule is enforced rather than remembered. There is no default value, no
/// zero fallback and no nullable double that a caller might quietly render as `0.0`. A
/// [Measurement] is either [Measurement.ok] with a value, or [Measurement.failed] with a reason
/// a human can read — and every rendering path has to handle both, because [value] throws if
/// you reach for it on a failure.
///
/// The reason strings matter. "camera did not open" tells the person holding the handset
/// something; "error" does not.
library;

import 'package:meta/meta.dart';

@immutable
class Measurement<T> {
  const Measurement._({this.value, this.failureReason})
    : assert(
        value != null || failureReason != null,
        'a Measurement is either a value or a stated reason for its absence',
      );

  /// A value that was actually measured.
  factory Measurement.ok(T value) => Measurement._(value: value);

  /// A measurement that could not be taken. [reason] is shown to the operator verbatim.
  factory Measurement.failed(String reason) => Measurement._(failureReason: reason);

  final T? value;
  final String? failureReason;

  bool get isOk => value != null;
  bool get isFailed => !isOk;

  /// The measured value. Throws if the measurement failed — deliberately, so a caller cannot
  /// slip a placeholder into a report by forgetting to check.
  T get requireValue {
    final v = value;
    if (v == null) {
      throw StateError(
        'no measured value: $failureReason. '
        'Check isOk before reading, and render the failure reason instead.',
      );
    }
    return v;
  }

  /// Transform a successful measurement, carrying a failure through untouched.
  Measurement<R> map<R>(R Function(T) transform) =>
      isOk ? Measurement.ok(transform(requireValue)) : Measurement.failed(failureReason!);

  /// For display. Never returns a number when the measurement failed.
  String describe(String Function(T) format) =>
      isOk ? format(requireValue) : 'not measured — $failureReason';

  /// JSON form. A failed measurement serialises as an explicit failure, not as null, so a
  /// downstream reader cannot mistake it for an absent field.
  Map<String, Object?> toJson(Object? Function(T) encode) => isOk
      ? {'measured': true, 'value': encode(requireValue)}
      : {'measured': false, 'failure_reason': failureReason};

  @override
  String toString() => isOk ? 'Measurement.ok($value)' : 'Measurement.failed($failureReason)';
}
