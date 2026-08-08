/// What happened to a spot check, after the recording stops.
///
/// This screen runs the terminal steps in order — analyse, register the handset if needed,
/// resolve the episode, submit — and then reports the outcome.
///
/// **It never shows a number.** Not a pressure, not a PTT, not the magnitude of a deviation. A
/// trend comes back as a direction and the backend's own wording; anything the backend did not
/// say, this screen does not invent. In this build the analysis step always rejects, and the
/// screen says so in those terms rather than implying the recording was at fault.
library;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../capture/device_measurement.dart';
import '../capture/eligibility_check.dart';
import '../capture/session_context.dart';
import '../capture/session_submitter.dart';
import '../debug/raw_capture_export.dart';
import '../signal/signal_pipeline.dart';
import 'capture_screen.dart';
import 'tokens.dart';

/// The terminal steps, in the order they run. Named so the screen can say which one is in
/// progress and, if something fails, which one failed.
enum _Stage {
  analysing('Working out the result'),
  measuringDevice('Checking this phone'),
  resolving('Finding your monitoring record'),
  submitting('Saving the spot check'),
  done('');

  const _Stage(this.label);

  final String label;
}

class SessionResultScreen extends StatefulWidget {
  const SessionResultScreen({
    super.key,
    required this.api,
    required this.capture,
    required this.eligibility,
    required this.onDone,
  });

  final ApiClient api;
  final CaptureResult capture;

  /// Carries the measurements the eligibility probe already made, so the patient is not asked to
  /// sit through them a second time.
  final EligibilityResult eligibility;
  final VoidCallback onDone;

  @override
  State<SessionResultScreen> createState() => _SessionResultScreenState();
}

class _SessionResultScreenState extends State<SessionResultScreen> {
  _Stage _stage = _Stage.analysing;
  SubmissionOutcome? _outcome;
  String? _failure;
  String? _exportNote;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final signal = await const UnimplementedSignalPipeline().process(widget.capture);

      if (!mounted) return;
      setState(() => _stage = _Stage.measuringDevice);
      final capabilities = widget.eligibility.capabilities;
      final rate = widget.eligibility.achievedRateHz;
      if (capabilities == null || rate == null) {
        // Registration needs measured values and there is no substitute for them (invariant 9).
        throw const SessionContextFailure(
          'This phone was not fully measured, so the spot check could not be filed against it.',
        );
      }
      final measurements = await DeviceMeasurer().measure(
        capabilities: capabilities,
        accelRateHz: rate,
      );

      if (!mounted) return;
      setState(() => _stage = _Stage.resolving);
      final context = await SessionContextResolver(api: widget.api).resolve(measurements);

      if (!mounted) return;
      setState(() => _stage = _Stage.submitting);
      final outcome = await SessionSubmitter(api: widget.api).submit(
        episodeId: context.episodeId,
        deviceProfileId: context.deviceProfileId,
        startedAt: widget.capture.startedAt,
        signal: signal,
      );

      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _stage = _Stage.done;
      });
    } on DeviceMeasurementFailure catch (e) {
      _fail(e.reason);
    } on SessionContextFailure catch (e) {
      _fail(e.reason);
    } on ApiException catch (e) {
      // The recording is gone either way; say so rather than implying it is waiting somewhere.
      _fail('The spot check could not be saved. ${e.message}');
    } on Object catch (e) {
      _fail('The spot check could not be saved. $e');
    }
  }

  void _fail(String reason) {
    if (!mounted) return;
    setState(() {
      _failure = reason;
      _stage = _Stage.done;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Spot check')),
      body: Padding(
        padding: const EdgeInsets.all(TeraSpacing.md),
        child: _stage == _Stage.done ? _result() : _progress(),
      ),
    );
  }

  Widget _progress() => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const CircularProgressIndicator(),
      const SizedBox(height: TeraSpacing.lg),
      Text(
        _stage.label,
        style: const TextStyle(color: TeraColors.ink, fontSize: 16),
        textAlign: TextAlign.center,
      ),
    ],
  );

  Widget _result() {
    final failure = _failure;
    final outcome = _outcome;

    return ListView(
      children: [
        if (failure != null)
          _panel(
            title: 'Not saved',
            body: failure,
            // A failure to save is a system state, and system states are flagged by form rather
            // than by colour. Red and amber are reserved and never used for either.
            flagged: true,
          )
        else if (outcome != null) ...[
          _panel(
            title: outcome.accepted ? 'Recorded' : 'Recorded, but not used',
            // The backend's own wording. It is written to avoid implying a measurement, and
            // rewriting it here would put that guarantee in two places.
            body: outcome.message,
            flagged: !outcome.accepted,
          ),
          if (outcome.trendDirection != null) ...[
            const SizedBox(height: TeraSpacing.md),
            _panel(
              title: 'Compared with your usual range',
              body: _trendWording(outcome.trendDirection!),
            ),
          ],
        ],
        // Compile-time constant. In a build without --dart-define=TERA_DEBUG_CAPTURE the whole
        // branch is removed, so the raw export is absent rather than merely hidden.
        if (kDebugCaptureEnabled) ...[const SizedBox(height: TeraSpacing.md), _debugExport()],
        const SizedBox(height: TeraSpacing.lg),
        FilledButton(onPressed: widget.onDone, child: const Text('Done')),
      ],
    );
  }

  /// The raw-export affordance. Only compiled into a developer build.
  ///
  /// The terms are printed here rather than in a README, because the person about to tap it is
  /// the person who needs to have read them.
  Widget _debugExport() => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(TeraSpacing.md),
    decoration: systemFlagDecoration(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'DEVELOPER BUILD',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: TeraColors.ink,
          ),
        ),
        const SizedBox(height: TeraSpacing.sm),
        const Text(
          debugCaptureNotice,
          style: TextStyle(color: TeraColors.ink, height: 1.5, fontSize: 13),
        ),
        const SizedBox(height: TeraSpacing.md),
        OutlinedButton(onPressed: _exportRaw, child: const Text('Write raw signals to this phone')),
        if (_exportNote != null) ...[
          const SizedBox(height: TeraSpacing.sm),
          Text(
            _exportNote!,
            style: const TextStyle(color: TeraColors.ink800, fontSize: 12, height: 1.4),
          ),
        ],
      ],
    ),
  );

  Future<void> _exportRaw() async {
    try {
      final result = await exportRawCapture(widget.capture);
      if (!mounted) return;
      setState(() => _exportNote = 'Written to:\n${result.accelPath}\n${result.framesPath}');
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _exportNote = 'Export failed. $e');
    }
  }

  /// Direction in words, with no number attached.
  ///
  /// Invariant 1: a spot check produces a direction relative to the patient's own baseline, never
  /// a pressure. `magnitude_sd` is not rendered in the patient view at all.
  String _trendWording(String direction) => switch (direction) {
    'increase' =>
      'This spot check sits above your usual range. It is not a blood-pressure '
          'reading. Use your cuff to check.',
    'decrease' =>
      'This spot check sits below your usual range. It is not a blood-pressure '
          'reading. Use your cuff to check.',
    _ => 'This spot check sits within your usual range. It is not a blood-pressure reading.',
  };

  Widget _panel({required String title, required String body, bool flagged = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(TeraSpacing.md),
      decoration: flagged ? systemFlagDecoration() : panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: TeraColors.ink,
            ),
          ),
          const SizedBox(height: TeraSpacing.sm),
          Text(body, style: const TextStyle(color: TeraColors.ink, height: 1.5)),
        ],
      ),
    );
  }
}
