/// Smoke test: does every code path work on this handset?
///
/// Five seconds per stage instead of sixty, for the half hour spent debugging HAL behaviour on
/// the first handset before real collection starts. It exercises the same calls as a full run —
/// characteristics, clocks, accelerometer, camera, ROI processing, thermal — and reports
/// pass/fail per stage.
///
/// **It is a separate type from [ProfileResult], deliberately.** There is no conversion between
/// them, no `smoke: true` flag on a shared type, and no path from a [SmokeReport] to a markdown
/// row or to the upload. Five seconds of camera is not a sustained-rate measurement and never
/// becomes one, so the way to guarantee smoke numbers never reach the proposal's device table
/// is for the code that builds that table to be unable to accept them.
///
/// The observed values are shown anyway, because they are exactly what makes a debugging loop
/// fast — labelled as indicative, in a type that cannot be exported.
library;

import 'package:meta/meta.dart';

@immutable
class StageOutcome {
  const StageOutcome({
    required this.name,
    required this.passed,
    required this.detail,
  });

  const StageOutcome.pass(String name, String detail)
    : this(name: name, passed: true, detail: detail);

  const StageOutcome.fail(String name, String detail)
    : this(name: name, passed: false, detail: detail);

  final String name;
  final bool passed;

  /// What was observed, or why it failed. Indicative only — five seconds is not a measurement.
  final String detail;
}

@immutable
class SmokeReport {
  const SmokeReport({required this.stages, required this.ranAt});

  final List<StageOutcome> stages;
  final DateTime ranAt;

  int get passedCount => stages.where((s) => s.passed).length;
  bool get allPassed => stages.every((s) => s.passed);

  List<StageOutcome> get failures => stages.where((s) => !s.passed).toList(growable: false);

  /// A one-line summary for the log.
  String get summary => allPassed
      ? 'All $passedCount stages passed. The handset is ready for a full run.'
      : '$passedCount of ${stages.length} stages passed. '
            'Failed: ${failures.map((f) => f.name).join(', ')}.';

  /// Plain text for copying into a debugging note. Not a results artefact — the header says so.
  String toPlainText() {
    final buffer = StringBuffer()
      ..writeln('Tera profiler — SMOKE TEST (5 s per stage)')
      ..writeln('NOT MEASUREMENT DATA. Five seconds is not a sustained-rate measurement,')
      ..writeln('and these numbers must not go into the device eligibility table.')
      ..writeln('Run at ${ranAt.toUtc().toIso8601String()}')
      ..writeln();
    for (final stage in stages) {
      buffer.writeln('${stage.passed ? "PASS" : "FAIL"}  ${stage.name}');
      buffer.writeln('      ${stage.detail}');
    }
    buffer
      ..writeln()
      ..writeln(summary);
    return buffer.toString();
  }
}
