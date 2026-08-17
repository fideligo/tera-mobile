/// INS-01 / INS-02 — the insight, fetched from the backend.
///
/// **The wording is not composed here.** The backend's rule engine returns codes and its language
/// layer returns the sentences; this screen lays them out. Composing copy on the handset would put
/// a second, unreviewed voice in front of a patient and would drift from the server's the moment
/// either changed.
///
/// Section 23's four blocks, in order: Hero Result, What This Means, Around This Check, and Your
/// Next Best Step.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../routing/app_router.dart';
import '../signal/signal_pipeline.dart';
import 'cuff_reading_screen.dart';
import 'tokens.dart';

class InsightScreen extends StatefulWidget {
  const InsightScreen({
    super.key,
    required this.api,
    required this.sessionId,
    this.uncalibratedDemo = false,
    this.aiConsent,
    this.localSignal,
  });

  final ApiClient api;

  /// Null when the check produced no session — BP-only, or a submission that never landed.
  final String? sessionId;

  /// BPREF-01 was skipped for this session (the no-cuff demo bypass). The backend's own
  /// confidence gating runs regardless; this only adds a standing warning above whatever it
  /// decides, so the missing reference is never silently absent from the screen a patient reads.
  final bool uncalibratedDemo;

  /// The answer already given on the processing screen, before this screen was built.
  ///
  /// `true` loads the insight with `ai_consent=true` in one request, so the commentary is present
  /// on first paint rather than appearing a second later. `false` is a decision to respect: this
  /// screen must not re-ask a question the patient has already declined. `null` means they were
  /// never asked — the submission failed before the question could be put — and only then does
  /// this screen ask for itself.
  final bool? aiConsent;

  /// What this handset derived on its own, kept so the screen has something true to show when the
  /// server cannot be reached at all.
  ///
  /// **This is the offline result, not a placeholder for the online one.** The two are different
  /// in kind: the server compares this check against the patient's cuff baseline and produces a
  /// *trend*; the handset has no baseline and can only report what it just measured. Presenting
  /// the second as though it were the first is the one thing this screen must not do, so the
  /// offline card shows a heart rate and signal figures and explicitly says no trend is available.
  final SignalResult? localSignal;

  @override
  State<InsightScreen> createState() => _InsightScreenState();
}

class _InsightScreenState extends State<InsightScreen> {
  Map<String, dynamic>? _insight;
  String? _error;
  bool _contraindicated = false;

  /// The consent question is asked once the deterministic result is on screen, and once per
  /// screen — [_askAiConsent] guards on this so a rebuild does not show the dialog twice.
  bool _aiConsentAsked = false;
  bool _aiLoading = false;

  /// How long the AI paragraph gets before the screen stops waiting for it.
  static const _aiDeadline = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _contraindicated = false;
    });

    final id = widget.sessionId;
    if (id == null) {
      // Reworded because the old text described the wrong thing. A null id does not mean the
      // check produced nothing — the capture ran and the session was submitted. It means the
      // check session could not be opened against the server, so there is nothing to *ask* about.
      // `ProcessingScreen` now retries opening one before reaching this screen; if it is still
      // null the server was unreachable for the whole check, and saying so is what lets someone
      // fix it in the next minute rather than wonder why the result is blank.
      setState(
        () => _error =
            'Your check was recorded on this phone, but Tera could not reach the server to '
            'explain it. Check the connection and try again.',
      );
      return;
    }
    try {
      // One request, with the answer already known where it is known.
      final consented = widget.aiConsent == true;
      final body = await widget.api.getJson(
        '/v1/check-sessions/$id/insight${consented ? '?ai_consent=true' : ''}',
        // Only the consented call waits on a third-party LLM. Past the deadline the screen
        // stops waiting rather than leaving a patient watching a spinner.
        timeout: consented ? _aiDeadline : null,
      );
      if (!mounted) return;
      setState(() => _insight = body);
      // Asked after the deterministic result is already the thing on screen: declining changes
      // nothing about what the patient just saw, it only decides whether one more paragraph
      // gets added underneath it.
      // Only when the processing screen never got to ask. A `false` there is a real refusal and
      // is not re-litigated here.
      if (widget.aiConsent == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _askAiConsent());
      }
    } on TimeoutException {
      // The AI half ran long. The deterministic result does not depend on it, so it is fetched
      // again without consent rather than lost along with it.
      debugPrint('[TERA] insight AI timed out; loading the deterministic result alone');
      if (!mounted) return;
      try {
        final body = await widget.api.getJson('/v1/check-sessions/$id/insight');
        if (!mounted) return;
        setState(() => _insight = body);
      } on Object catch (e) {
        if (mounted) setState(() => _error = 'Could not load your result. $e');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _contraindicated = e.statusCode == 403;
        _error = e.message;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load your result. $e');
    }
  }

  /// The consent dialog. Declining, or an unconfigured server, both end in exactly the screen
  /// this already is — the deterministic block above, unchanged. Nothing here can make the
  /// result the patient already sees worse or slower.
  Future<void> _askAiConsent() async {
    if (_aiConsentAsked || !mounted) return;
    _aiConsentAsked = true;

    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeraRadius.card),
        ),
        backgroundColor: TeraColors.paper,
        title: const Text(
          'Data Privacy Notice',
          style: TextStyle(fontWeight: FontWeight.w700, color: TeraColors.ink),
        ),
        content: const Text(
          'Your recording result and health profile — not the recording itself, and not your '
          'name — will be sent securely to a public AI API (NVIDIA) to generate insights. If '
          'you say no, you keep exactly the result shown above and nothing is sent anywhere.\n\n'
          'Do you consent?',
          style: TextStyle(color: TeraColors.ink, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No, thanks'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: TeraColors.ink,
              foregroundColor: TeraColors.paper,
            ),
            child: const Text('Yes, send it'),
          ),
        ],
      ),
    );

    if (consent == true) await _fetchAiCommentary();
  }

  Future<void> _fetchAiCommentary() async {
    final id = widget.sessionId;
    if (id == null || !mounted) return;
    setState(() => _aiLoading = true);
    try {
      final body = await widget.api.getJson(
        '/v1/check-sessions/$id/insight?ai_consent=true',
        timeout: _aiDeadline,
      );
      if (!mounted) return;
      // Merge rather than replace: a slow or failed AI call must never take the deterministic
      // block that is already correctly on screen back down to nothing.
      setState(() {
        _insight = {...?_insight, ...body};
        _aiLoading = false;
      });
    } on Object {
      // No AI key configured, the provider unreachable, or its answer tripped the invariant-6
      // filter server-side — all three are the same outcome here: nothing to show, and the
      // deterministic result stands on its own exactly as if consent had been declined.
      if (mounted) setState(() => _aiLoading = false);
    }
  }

  /// The cuff step, reached from the no-estimate card.
  ///
  /// Filing the reading is all this does. `CuffReadingScreen` writes it as a real `cuff_reading`
  /// and records it in `CalibrationAnchorStore`, which `ProcessingScreen` reads on the next check
  /// to establish the calibration against a capture — a calibration needs both, and there is no
  /// capture to anchor to from this screen.
  Future<void> _takeCuffReading() async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => CuffReadingScreen(
          api: widget.api,
          isReference: true,
          onDone: () => navigator.pop(),
        ),
      ),
    );
    if (!mounted) return;
    // The estimate for *this* check cannot change — it is computed from the calibration in force
    // when it was captured (invariant 4) — but the reference shown alongside it can, so the
    // screen is reloaded rather than left describing a state that has moved.
    await _load();
  }

  /// Systolic and diastolic for this check, or an honest account of why there are none.
  ///
  /// `estimated_systolic` / `estimated_diastolic` are computed on the server from *this capture's*
  /// PTT against the calibration in force (`app/services/pressure_estimate.py`). They are null
  /// whenever the model could not stand behind a number — no calibration, an anchor older than
  /// `max_calibration_age_days`, drift outside the linear range, a result outside the
  /// physiological clamps.
  ///
  /// **Null is rendered as an explanation and a way out, never as a number.** Invariant 1 permits
  /// an estimate only where a measured PTT went through the stated model; substituting a figure so
  /// the slot is never empty would put a pressure in front of a patient that no signal produced,
  /// which is the one thing both this file and that model refuse to do. What the patient gets
  /// instead is the reason and the action that fixes it — which is invariant 7's escalation, in
  /// the place where it is actually actionable.
  ///
  /// The estimate is an **outlined** card; a cuff reading is a **filled** one. That is standing
  /// constraint 1 and not decoration: the two are different kinds of claim and must not be
  /// mistaken for each other at a glance.
  Widget _estimateBlock(Map<String, dynamic> insight) {
    final estSys = insight['estimated_systolic'] as int?;
    final estDia = insight['estimated_diastolic'] as int?;
    final conf = (insight['estimate_confidence'] as num?)?.toDouble();
    final ageDays = insight['estimate_calibration_age_days'] as int?;
    final refSys = insight['reference_systolic'] as int?;
    final refDia = insight['reference_diastolic'] as int?;

    if (estSys == null || estDia == null) {
      final needsCalibration = refSys == null;
      return Container(
        padding: const EdgeInsets.all(TeraSpacing.md),
        decoration: systemFlagDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'No estimated reading for this check',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: TeraColors.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              needsCalibration
                  ? 'Take one reading with an upper-arm cuff to calibrate. After that, Tera '
                        'estimates your blood pressure from the phone check alone.'
                  : ageDays == null
                  ? 'This capture sits too far from your calibration for an estimate Tera can '
                        'stand behind. A fresh cuff reading restores the numbers.'
                  : 'Your calibration is $ageDays days old, and this capture sits too far from '
                        'it for an estimate Tera can stand behind. A fresh cuff reading '
                        'restores the numbers.',
              style: const TextStyle(
                color: TeraColors.ink,
                fontSize: TeraText.small,
                height: 1.45,
              ),
            ),
            const SizedBox(height: TeraSpacing.md),
            OutlinedButton(
              onPressed: _takeCuffReading,
              child: const Text('Take a cuff reading'),
            ),
          ],
        ),
      );
    }

    final confText = conf == null
        ? ''
        : ' · confidence ${(conf * 100).round()}%';

    return Container(
      padding: const EdgeInsets.all(20),
      // Outlined, never filled. The filled treatment belongs to a cuff-confirmed reading and to
      // nothing else.
      decoration: BoxDecoration(
        color: TeraColors.paper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TeraColors.baltic, width: 2),
      ),
      child: Column(
        children: [
          const Text(
            'ESTIMATED — NOT A CUFF READING',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: TeraColors.baltic,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '$estSys / $estDia',
            style: const TextStyle(
              fontSize: 46,
              fontWeight: FontWeight.w700,
              color: TeraColors.ink,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'mmHg, estimated from this check',
            style: TextStyle(
              fontSize: TeraText.small,
              color: TeraColors.neutral700,
            ),
          ),
          if (refSys != null && refDia != null) ...[
            const SizedBox(height: TeraSpacing.md),
            const Divider(height: 1),
            const SizedBox(height: TeraSpacing.sm),
            Text(
              'Calibrated against your cuff reading of '
              '$refSys / $refDia mmHg$confText',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: TeraText.micro,
                color: TeraColors.neutral700,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final insight = _insight;
    final error = _error;
    final local = widget.localSignal;

    return Scaffold(
      backgroundColor: TeraColors.page,
      appBar: AppBar(title: const Text('Your result')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  children: [
                    // **The measured figures come first and are never conditional on the server.**
                    //
                    // Heart rate is derived on this handset from the camera signal. It does not
                    // depend on the network, on a calibration, or on the insight request having
                    // succeeded, so it is rendered before any of them are consulted — a patient
                    // who has just held still for a minute sees what was measured even when
                    // everything downstream of the capture has failed.
                    //
                    // It is deliberately not in the same visual language as either a cuff reading
                    // or an estimate: it is a rate, directly measured, and neither of those.
                    if (local != null && !_contraindicated) ...[
                      _HeartRateCard(bpm: local.heartRateBpm),
                      const SizedBox(height: TeraSpacing.md),
                    ],

                    // Server unreachable, not signed in, timed out, refused — every one of them
                    // lands here, and every one of them still has the on-device result above it.
                    if (error != null && !_contraindicated && local != null) ...[
                      _LocalResultCard(signal: local, onRetry: _load),
                    ] else if (error != null) ...[
                      // The system-state treatment, not a red alarm. Red is not in this palette
                      // (working root `CLAUDE.md`, standing constraint 5) and, more to the point,
                      // an unreachable server is something *the system* failed at — it says
                      // nothing about the patient, and colouring it like a medical warning
                      // implies it does.
                      Container(
                        padding: const EdgeInsets.all(TeraSpacing.md),
                        decoration: systemFlagDecoration(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _contraindicated
                                  ? 'Tera cannot produce a trend'
                                  : 'Your check was saved',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: TeraColors.ink,
                                fontSize: TeraText.body,
                              ),
                            ),
                            const SizedBox(height: TeraSpacing.sm),
                            Text(
                              error,
                              style: const TextStyle(
                                color: TeraColors.ink,
                                height: 1.4,
                              ),
                            ),
                            if (!_contraindicated) ...[
                              const SizedBox(height: TeraSpacing.md),
                              OutlinedButton(
                                onPressed: _load,
                                child: const Text('Try again'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ] else if (insight == null) ...[
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    ] else ...[
                      if (widget.uncalibratedDemo) ...[
                        Container(
                          padding: const EdgeInsets.all(TeraSpacing.md),
                          decoration: systemFlagDecoration(),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: TeraColors.plum,
                                size: 20,
                              ),
                              const SizedBox(width: TeraSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Without a tensimeter, this BP-related trend is an '
                                      'uncalibrated estimate.',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: TeraColors.ink,
                                        height: 1.35,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Calibration was skipped for this check (demo mode, no '
                                      'cuff reading). Nothing below is a blood-pressure value — '
                                      'it is a rough directional estimate only, with no '
                                      'personal reference to compare against.',
                                      style: TextStyle(
                                        color: TeraColors.ink,
                                        fontSize: TeraText.small,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: TeraSpacing.md),
                      ],
                      // The estimated reading, directly under the measured heart rate and above
                      // everything the server *interprets*. It was below the AI paragraph, so
                      // the two numbers a patient came for sat under a scroll and under an
                      // optional third-party paragraph.
                      _estimateBlock(insight),
                      const SizedBox(height: 16),

                      // 23.1 Hero Result
                      Builder(
                        builder: (context) {
                          // The backend's field is `hero` (see `_render()` in
                          // `app/api/v1/phr.py`). This read `hero_result`, a key the response has
                          // never had, so this line always showed its fallback text — the result
                          // of every check, silently blank.
                          //
                          // The fallback itself was the string 'No result', which is what the
                          // patient actually read. There is no state in which that is true: the
                          // check ran and the figures above are from it. A response that arrived
                          // without a trend means the trend is what is missing, so the block that
                          // shows the trend is what goes, rather than the screen announcing that
                          // nothing happened.
                          final hero = insight['hero'] as String?;
                          if (hero == null || hero.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Container(
                            padding: const EdgeInsets.all(TeraSpacing.lg),
                            decoration: BoxDecoration(
                              color: TeraColors.paper,
                              borderRadius: TeraRadius.cardBorder,
                              border: Border.all(color: TeraColors.neutral200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                const Text(
                                  'BP-RELATED TREND',
                                  style: TextStyle(
                                    fontSize: TeraText.micro,
                                    fontWeight: FontWeight.w700,
                                    color: TeraColors.neutral700,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                const SizedBox(height: TeraSpacing.sm),
                                Text(
                                  hero,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: TeraText.display,
                                    fontWeight: FontWeight.w700,
                                    color: TeraColors.ink,
                                    height: 1.2,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),

                      // The consent-gated AI paragraph (Task 4). `ai_commentary` is present and
                      // non-null only when the patient said yes, a key is configured, the call
                      // succeeded, and the invariant-6 filter passed it — every other outcome
                      // (declined, unconfigured, unreachable, refused) leaves this whole block
                      // absent and the deterministic result above stands alone. Placed directly
                      // under the hero, not at the foot of the screen, so consenting actually
                      // renders it prominently rather than requiring a scroll to find.
                      if (_aiLoading) ...[
                        const SizedBox(height: 16),
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                      ] else if (insight['ai_commentary'] != null &&
                          (insight['ai_commentary'] as String).isNotEmpty) ...[
                        const SizedBox(height: 16),
                        // **This card was green.** Mint-and-emerald on a health result is a
                        // colour that says "good", and the palette rule at the top of
                        // `tokens.dart` is explicit: no green-for-good and no red-for-bad, because
                        // a hue is a clinical judgement the system is not entitled to make. It is
                        // worse here than anywhere else — this is the one block written by a
                        // language model and *not* reviewed by a clinician, so it is the last
                        // thing that should be tinted with reassurance.
                        //
                        // It is set apart by form now: a baltic rule and a label, the same
                        // vocabulary the rest of the app uses for "this is a different kind of
                        // thing".
                        Container(
                          padding: const EdgeInsets.all(TeraSpacing.md),
                          decoration: const BoxDecoration(
                            color: TeraColors.neutral50,
                            border: Border(
                              left: BorderSide(
                                color: TeraColors.baltic,
                                width: 3,
                              ),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.auto_awesome_outlined,
                                size: 20,
                                color: TeraColors.baltic,
                              ),
                              const SizedBox(width: TeraSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'AI-GENERATED · NOT REVIEWED BY A CLINICIAN',
                                      style: TextStyle(
                                        fontSize: TeraText.micro,
                                        fontWeight: FontWeight.w700,
                                        color: TeraColors.baltic,
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      insight['ai_commentary'] as String,
                                      style: const TextStyle(
                                        fontSize: TeraText.small,
                                        color: TeraColors.ink,
                                        height: 1.45,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],


                      const SizedBox(height: 24),
                      // 23.3 What This Means. The backend has no single "what_this_means"
                      // string (there never was one to read); this composes the section from
                      // the fields it actually returns — the context chips CTX-01 fed into
                      // this result, and the two standing disclaimers every insight carries.
                      Builder(
                        builder: (context) {
                          final whatThisMeans = insight['what_this_means'] as String?;
                          if (whatThisMeans == null || whatThisMeans.isEmpty)
                            return const SizedBox.shrink();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'What this means',
                                style: TextStyle(
                                  fontSize: TeraText.body,
                                  fontWeight: FontWeight.w700,
                                  color: TeraColors.ink,
                                ),
                              ),
                              const SizedBox(height: TeraSpacing.sm),
                              Container(
                                padding: const EdgeInsets.all(TeraSpacing.md),
                                decoration: BoxDecoration(
                                  color: TeraColors.paper,
                                  borderRadius: TeraRadius.cardBorder,
                                  border: Border.all(
                                    color: TeraColors.neutral200,
                                  ),
                                ),
                                child: Text(
                                  whatThisMeans,
                                  style: const TextStyle(
                                    fontSize: TeraText.small,
                                    color: TeraColors.ink,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),
                            ],
                          );
                        },
                      ),

                      // 23.4 Your Next Best Step
                      // The one thing on this screen a patient is meant to *do*, so it is the one
                      // element that gets the accent. Mint is a system-side highlight here — "here
                      // is your next action" — and not a verdict on the reading above it.
                      Container(
                        padding: const EdgeInsets.all(TeraSpacing.md),
                        decoration: confirmationDecoration(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.flag_outlined,
                                  color: TeraColors.brand,
                                  size: 20,
                                ),
                                SizedBox(width: TeraSpacing.sm),
                                Text(
                                  'Your next best step',
                                  style: TextStyle(
                                    fontSize: TeraText.body,
                                    fontWeight: FontWeight.w700,
                                    color: TeraColors.ink,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: TeraSpacing.sm),
                            Text(
                              insight['next_best_step'] as String? ??
                                  'Keep monitoring your blood pressure as usual.',
                              style: const TextStyle(
                                fontSize: TeraText.small,
                                color: TeraColors.ink,
                                height: 1.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => TeraFlow.toHome(context),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Heart rate for this check, measured on this handset.
///
/// **Its own card, and its own visual language.** A cuff reading is a solid fill with large
/// numerals; an estimate is an outline carrying "ESTIMATED — NOT A CUFF READING" (standing
/// constraint 1). A heart rate is neither — it is a rate, derived directly from the camera signal
/// rather than modelled from it — so it is rendered as neutral measured data and labelled with
/// where it came from, which keeps all three distinguishable at a glance.
///
/// Shown whether or not the server was reachable, because nothing about it depends on the server.
class _HeartRateCard extends StatelessWidget {
  const _HeartRateCard({required this.bpm});

  /// Null when the chain could not derive one. Rendered as a dash, never as a plausible number.
  final double? bpm;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(TeraSpacing.lg),
      decoration: BoxDecoration(
        color: TeraColors.paper,
        borderRadius: BorderRadius.circular(TeraRadius.card),
        border: Border.all(color: TeraColors.neutral300),
      ),
      child: Column(
        children: [
          const Text(
            'HEART RATE — MEASURED THIS CHECK',
            style: TextStyle(
              fontSize: TeraText.micro,
              fontWeight: FontWeight.w700,
              color: TeraColors.neutral700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: TeraSpacing.sm),
          Text(
            bpm == null ? '--' : bpm!.round().toString(),
            style: const TextStyle(
              fontSize: 46,
              fontWeight: FontWeight.w700,
              color: TeraColors.ink,
              height: 1.0,
            ),
          ),
          const Text(
            'beats per minute',
            style: TextStyle(
              fontSize: TeraText.small,
              color: TeraColors.neutral700,
            ),
          ),
        ],
      ),
    );
  }
}

/// The offline result: what this handset measured, when the server could not be asked.
///
/// Everything on this card is a real figure out of the capture that just ran. There is
/// deliberately **no trend and no direction** here, not even a neutral-looking one: a trend is
/// defined against the patient's own cuff baseline, that baseline lives server-side, and inventing
/// a "stable" to fill the space would be asserting the one thing this screen cannot know. Saying
/// "no comparison available" is both true and, on a result screen someone may act on, safer.
class _LocalResultCard extends StatelessWidget {
  const _LocalResultCard({required this.signal, required this.onRetry});

  final SignalResult signal;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final accelHz = (signal.quality['accel_rate_hz'] as num?)?.toDouble();
    final cameraFps = (signal.quality['camera_fps'] as num?)?.toDouble();

    // The heart rate itself is no longer repeated here: `_HeartRateCard` renders it above this
    // card on every path, reachable or not, so this one is now purely the explanation of what
    // could not be produced and why.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(TeraSpacing.md),
          decoration: systemFlagDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Local analysis only',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: TeraColors.ink,
                  fontSize: TeraText.body,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Your recording finished and was analysed on this phone. It was not sent to '
                'the server — either you are using Tera as a guest, or the server could not be '
                'reached — so nothing was saved and no blood-pressure trend is available. A '
                'trend is measured against your own cuff baseline, and that comparison only '
                'happens server-side. The heart rate above is from this recording.',
                style: TextStyle(
                  color: TeraColors.ink,
                  fontSize: TeraText.small,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: TeraSpacing.md),
              Text(
                'Signal: ${signal.nBeatsUsable} usable beats'
                '${cameraFps == null ? '' : ' · camera ${cameraFps.toStringAsFixed(0)} fps'}'
                '${accelHz == null ? '' : ' · motion ${accelHz.toStringAsFixed(0)} Hz'}',
                style: const TextStyle(
                  fontSize: TeraText.micro,
                  color: TeraColors.neutral700,
                ),
              ),
              if (accelHz != null && accelHz < 200) ...[
                const SizedBox(height: 6),
                Text(
                  'Motion sensor ran at ${accelHz.toStringAsFixed(0)} Hz, below the 200 Hz this '
                  'method needs. Transit-time figures from this capture are not reliable.',
                  style: const TextStyle(
                    fontSize: TeraText.micro,
                    color: TeraColors.ink,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: TeraSpacing.md),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('Try the server again'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
