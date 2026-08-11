/// Identifies the capture-and-analysis chain that produced a session.
///
/// Sent as `model_version` so a record carries the version of the code that made it. The
/// `-nosignal` suffix is deliberate and load-bearing: every session submitted by this build is
/// marked, in the clinical record itself, as coming from a build with no signal chain. If these
/// rows are ever examined later, nothing about their provenance has to be reconstructed from
/// memory.
library;

/// Provenance for every row this build writes.
///
/// `-nosignal` is gone: the chain is the ML team's `tera_ptt.py`, ported to Dart and pinned
/// against it in `test/ptt_reference_test.dart`. The version carries the reference it was
/// ported from, so a row can be traced to the algorithm that produced it.
const String signalPipelineVersion = 'tera-patient-0.2.0-ptt-dart-r1';
