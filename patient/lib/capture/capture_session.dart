/// Identifies the capture-and-analysis chain that produced a session.
///
/// Sent as `model_version` so a record carries the version of the code that made it. The
/// `-nosignal` suffix is deliberate and load-bearing: every session submitted by this build is
/// marked, in the clinical record itself, as coming from a build with no signal chain. If these
/// rows are ever examined later, nothing about their provenance has to be reconstructed from
/// memory.
library;

const String signalPipelineVersion = 'tera-patient-0.1.0-nosignal';
