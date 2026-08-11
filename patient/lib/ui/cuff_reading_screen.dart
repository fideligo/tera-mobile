/// Entering a cuff reading, confirming it, and saving it.
///
/// Two ways in, one way out. Photograph the tensimeter and get a *suggestion*, or type the numbers
/// yourself — and **both routes end at a person explicitly confirming the numerals before anything
/// is saved.** The submit call is reachable only from a confirm stage, and a confirm stage is the
/// only place a `ConfirmedCuffReading` is constructed.
///
/// # The OCR path does not shorten the flow, it only pre-fills it
///
/// A confident misread of a seven-segment display is exactly the failure this is built to catch:
/// an 8 read as a 6 looks precisely as confident as an 8 read as an 8. So the extractor's
/// confidence is shown and never acted on, there is no threshold above which the app saves without
/// asking, and the suggestion screen's two actions are "Correct, save" and "Edit". Nothing here
/// auto-saves.
///
/// Because a person confirmed the numerals, a reading entered this way is still submitted as
/// `manual_entry`. `source = 'photograph'` would assert that the *system* read the display and
/// stands behind the value; nothing in this build does.
///
/// The confirmation screens show the numerals at display size, because the thing being confirmed
/// is the numerals and a 15pt echo of what was just typed confirms nothing. This is the one place
/// in the patient app where large numerals are correct — they are a cuff measurement, which is
/// exactly what invariant 1 reserves that treatment for.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../capture/cuff_ocr.dart';
import '../capture/cuff_reading.dart';
import '../capture/session_context.dart';
import 'tokens.dart';

enum _Stage { choose, reading, suggestion, enter, confirm, saved }

class CuffReadingScreen extends StatefulWidget {
  const CuffReadingScreen({
    super.key,
    required this.api,
    required this.onDone,
    this.ocr = const MockCuffOcrExtractor(),
  });

  final ApiClient api;
  final VoidCallback onDone;

  /// Injectable so a test can drive the flow without waiting on the mock's delay.
  final CuffOcrExtractor ocr;

  @override
  State<CuffReadingScreen> createState() => _CuffReadingScreenState();
}

class _CuffReadingScreenState extends State<CuffReadingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _systolic = TextEditingController();
  final _diastolic = TextEditingController();
  final _pulse = TextEditingController();

  _Stage _stage = _Stage.choose;
  DraftCuffReading? _draft;
  CuffOcrReading? _suggestion;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _systolic.dispose();
    _diastolic.dispose();
    _pulse.dispose();
    super.dispose();
  }

  /// Mock capture. No camera is opened and no image exists; see `cuff_ocr.dart`.
  Future<void> _photograph() async {
    setState(() {
      _stage = _Stage.reading;
      _error = null;
    });

    final reading = await widget.ocr.extract();
    if (!mounted) return;

    setState(() {
      _suggestion = reading;
      // A suggestion, not a draft. It becomes a draft only when a person accepts or edits it.
      _stage = _Stage.suggestion;
    });
  }

  /// "Correct, save" — the explicit confirmation for the OCR route.
  Future<void> _acceptSuggestion() async {
    final suggestion = _suggestion;
    if (suggestion == null) return;

    final draft = DraftCuffReading(
      systolicMmhg: suggestion.systolicMmhg,
      diastolicMmhg: suggestion.diastolicMmhg,
      pulseBpm: suggestion.pulseBpm,
    );

    final violations = draft.validate();
    if (violations.isNotEmpty) {
      // An implausible suggestion is never savable, however confident the extractor was. Drop the
      // patient into the form with it pre-filled rather than into a dead end.
      setState(() => _error = violations.first.message);
      _editSuggestion();
      return;
    }

    setState(() => _draft = draft);
    await _confirmAndSave();
  }

  /// "Edit" — the same numbers, in the form, for a person to correct.
  void _editSuggestion() {
    final suggestion = _suggestion;
    if (suggestion != null) {
      _systolic.text = '${suggestion.systolicMmhg}';
      _diastolic.text = '${suggestion.diastolicMmhg}';
      _pulse.text = suggestion.pulseBpm?.toString() ?? '';
    }
    setState(() => _stage = _Stage.enter);
  }

  void _review() {
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final draft = DraftCuffReading(
      systolicMmhg: int.parse(_systolic.text.trim()),
      diastolicMmhg: int.parse(_diastolic.text.trim()),
      pulseBpm: _pulse.text.trim().isEmpty ? null : int.parse(_pulse.text.trim()),
    );

    // The cross-field rules the per-field validators cannot see.
    final violations = draft.validate();
    if (violations.isNotEmpty) {
      setState(() => _error = violations.first.message);
      return;
    }

    setState(() {
      _draft = draft;
      _stage = _Stage.confirm;
    });
  }

  Future<void> _confirmAndSave() async {
    final draft = _draft;
    if (draft == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // Confirmation happens here, at the tap, and is stamped with that instant.
      final confirmed = draft.confirm();
      final resolver = SessionContextResolver(api: widget.api);
      final (:patientId, :episodeId) = await resolver.resolveEpisode();
      await CuffReadingSubmitter(api: widget.api).submit(
        reading: confirmed,
        episodeId: episodeId,
      );
      if (!mounted) return;
      setState(() {
        _stage = _Stage.saved;
        _busy = false;
      });
    } on SessionContextFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.reason;
        _busy = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'The reading could not be saved. $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cuff reading')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(TeraSpacing.md),
          children: switch (_stage) {
            _Stage.choose => _chooseStage(),
            _Stage.reading => _readingStage(),
            _Stage.suggestion => _suggestionStage(),
            _Stage.enter => _enterStage(),
            _Stage.confirm => _confirmStage(),
            _Stage.saved => _savedStage(),
          },
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- choose ----

  List<Widget> _chooseStage() => [
    const Text(
      'Record a cuff reading',
      style: TextStyle(
        fontSize: TeraText.section,
        fontWeight: FontWeight.w600,
        color: TeraColors.ink,
      ),
    ),
    const SizedBox(height: TeraSpacing.sm),
    const Text(
      'These are blood-pressure measurements — the only kind Tera records. Photograph the display '
      'and check what Tera reads, or type the numbers in yourself.',
      style: TextStyle(color: TeraColors.ink, height: 1.5),
    ),
    const SizedBox(height: TeraSpacing.lg),
    FilledButton(onPressed: _photograph, child: const Text('Photograph tensimeter')),
    const SizedBox(height: TeraSpacing.md),
    OutlinedButton(
      onPressed: () => setState(() => _stage = _Stage.enter),
      child: const Text('Type the numbers in'),
    ),
    const SizedBox(height: TeraSpacing.lg),
    const Text(
      'Whichever you choose, Tera shows you the numbers and waits for you to confirm them before '
      'saving anything.',
      style: TextStyle(fontSize: TeraText.small, height: 1.5, color: TeraColors.neutral700),
    ),
  ];

  // ---------------------------------------------------------------- reading ----

  List<Widget> _readingStage() => [
    const SizedBox(height: TeraSpacing.xl),
    const LinearProgressIndicator(),
    const SizedBox(height: TeraSpacing.lg),
    const Text(
      'Reading the display…',
      style: TextStyle(
        fontSize: TeraText.section,
        fontWeight: FontWeight.w600,
        color: TeraColors.ink,
      ),
    ),
  ];

  // ------------------------------------------------------------- suggestion ----

  List<Widget> _suggestionStage() {
    final suggestion = _suggestion!;
    return [
      const Text(
        'Check what Tera read',
        style: TextStyle(
          fontSize: TeraText.section,
          fontWeight: FontWeight.w600,
          color: TeraColors.ink,
        ),
      ),
      const SizedBox(height: TeraSpacing.sm),
      const Text(
        'Compare these against the display on your cuff. If they do not match exactly, choose Edit '
        'and correct them.',
        style: TextStyle(color: TeraColors.ink, height: 1.5),
      ),

      if (suggestion.simulated) ...[
        const SizedBox(height: TeraSpacing.md),
        Container(
          decoration: systemFlagDecoration(),
          padding: const EdgeInsets.all(TeraSpacing.md),
          child: const Text(
            simulatedOcrNotice,
            style: TextStyle(color: TeraColors.ink, height: 1.4),
          ),
        ),
      ],

      const SizedBox(height: TeraSpacing.lg),
      Container(
        decoration: panelDecoration(),
        padding: const EdgeInsets.all(TeraSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'We read',
              style: TextStyle(fontSize: TeraText.small, color: TeraColors.neutral700),
            ),
            const SizedBox(height: TeraSpacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${suggestion.systolicMmhg} / ${suggestion.diastolicMmhg}',
                  style: const TextStyle(
                    fontSize: TeraText.display,
                    fontWeight: FontWeight.w700,
                    color: TeraColors.ink,
                  ),
                ),
                const SizedBox(width: TeraSpacing.sm),
                const Text(
                  'mmHg',
                  style: TextStyle(fontSize: TeraText.body, color: TeraColors.neutral700),
                ),
              ],
            ),
            if (suggestion.pulseBpm != null) ...[
              const SizedBox(height: TeraSpacing.sm),
              Text(
                'Pulse ${suggestion.pulseBpm} bpm',
                style: const TextStyle(fontSize: TeraText.body, color: TeraColors.ink),
              ),
            ],
            const SizedBox(height: TeraSpacing.md),
            Text(
              // Reported, never acted on. There is no confidence at which this screen is skipped.
              'Tera is ${(suggestion.confidence * 100).round()}% sure it read this correctly. '
              'That is not a check on whether the numbers are right — only you can do that.',
              style: const TextStyle(
                fontSize: TeraText.small,
                height: 1.5,
                color: TeraColors.neutral700,
              ),
            ),
          ],
        ),
      ),

      if (_error != null) ...[
        const SizedBox(height: TeraSpacing.md),
        _errorPanel(_error!),
      ],

      const SizedBox(height: TeraSpacing.lg),
      FilledButton(
        onPressed: _busy ? null : _acceptSuggestion,
        child: Text(_busy ? 'Saving…' : 'Correct, save'),
      ),
      const SizedBox(height: TeraSpacing.md),
      OutlinedButton(
        onPressed: _busy ? null : _editSuggestion,
        child: const Text('Edit'),
      ),
    ];
  }

  // ------------------------------------------------------------------ enter ----

  List<Widget> _enterStage() => [
    const Text(
      'Type in your cuff reading',
      style: TextStyle(
        fontSize: TeraText.section,
        fontWeight: FontWeight.w600,
        color: TeraColors.ink,
      ),
    ),
    const SizedBox(height: TeraSpacing.sm),
    const Text(
      'Use the numbers shown on your upper-arm cuff. These are a blood-pressure measurement — '
      'the only kind Tera records.',
      style: TextStyle(color: TeraColors.ink, height: 1.5),
    ),
    const SizedBox(height: TeraSpacing.lg),
    Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _numberField(
            controller: _systolic,
            label: 'Top number (systolic), mmHg',
            min: systolicMinMmhg,
            max: systolicMaxMmhg,
          ),
          const SizedBox(height: TeraSpacing.md),
          _numberField(
            controller: _diastolic,
            label: 'Bottom number (diastolic), mmHg',
            min: diastolicMinMmhg,
            max: diastolicMaxMmhg,
          ),
          const SizedBox(height: TeraSpacing.md),
          _numberField(
            controller: _pulse,
            label: 'Pulse, beats per minute (optional)',
            min: pulseMinBpm,
            max: pulseMaxBpm,
            optional: true,
          ),
        ],
      ),
    ),
    if (_error != null) ...[
      const SizedBox(height: TeraSpacing.md),
      _errorPanel(_error!),
    ],
    const SizedBox(height: TeraSpacing.lg),
    FilledButton(onPressed: _review, child: const Text('Review')),
    const SizedBox(height: TeraSpacing.md),
    const Text(
      'Tera does not read your cuff from a photograph. Typing the numbers in is the only way, so '
      'what is recorded is what you saw.',
      style: TextStyle(fontSize: TeraText.small, height: 1.5, color: TeraColors.neutral700),
    ),
  ];

  Widget _numberField({
    required TextEditingController controller,
    required String label,
    required int min,
    required int max,
    bool optional = false,
  }) => TextFormField(
    controller: controller,
    decoration: InputDecoration(labelText: label),
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    textInputAction: TextInputAction.next,
    validator: (v) {
      final text = (v ?? '').trim();
      if (text.isEmpty) return optional ? null : 'Enter this number.';
      final value = int.tryParse(text);
      if (value == null) return 'Digits only.';
      if (value < min || value > max) return 'Must be between $min and $max.';
      return null;
    },
  );

  // ---------------------------------------------------------------- confirm ----

  List<Widget> _confirmStage() {
    final draft = _draft!;
    return [
      const Text(
        'Is this what your cuff showed?',
        style: TextStyle(
          fontSize: TeraText.section,
          fontWeight: FontWeight.w600,
          color: TeraColors.ink,
        ),
      ),
      const SizedBox(height: TeraSpacing.sm),
      const Text(
        'Check the numbers against the display before saving. A saved reading becomes the '
        'reference your spot checks are compared against, and it cannot be edited afterwards — a '
        'correction is recorded as a new reading.',
        style: TextStyle(color: TeraColors.ink, height: 1.5),
      ),
      const SizedBox(height: TeraSpacing.lg),
      Container(
        decoration: panelDecoration(),
        padding: const EdgeInsets.all(TeraSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${draft.systolicMmhg}/${draft.diastolicMmhg}',
                  style: const TextStyle(
                    fontSize: TeraText.display,
                    fontWeight: FontWeight.w700,
                    color: TeraColors.ink,
                  ),
                ),
                const SizedBox(width: TeraSpacing.sm),
                const Text(
                  'mmHg',
                  style: TextStyle(fontSize: TeraText.body, color: TeraColors.neutral700),
                ),
              ],
            ),
            if (draft.pulseBpm != null) ...[
              const SizedBox(height: TeraSpacing.sm),
              Text(
                'Pulse ${draft.pulseBpm} bpm',
                style: const TextStyle(fontSize: TeraText.body, color: TeraColors.ink),
              ),
            ],
          ],
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: TeraSpacing.md),
        _errorPanel(_error!),
      ],
      const SizedBox(height: TeraSpacing.lg),
      FilledButton(
        onPressed: _busy ? null : _confirmAndSave,
        child: Text(_busy ? 'Saving…' : 'Confirm and save'),
      ),
      const SizedBox(height: TeraSpacing.md),
      OutlinedButton(
        onPressed: _busy ? null : () => setState(() => _stage = _Stage.enter),
        child: const Text('Go back and change'),
      ),
    ];
  }

  // ------------------------------------------------------------------ saved ----

  List<Widget> _savedStage() => [
    const Text(
      'Reading saved',
      style: TextStyle(
        fontSize: TeraText.section,
        fontWeight: FontWeight.w600,
        color: TeraColors.ink,
      ),
    ),
    const SizedBox(height: TeraSpacing.sm),
    const Text(
      'It is now part of your record and your clinic can see it. Tera does not say what the '
      'numbers mean — that is a conversation with your clinician.',
      style: TextStyle(color: TeraColors.ink, height: 1.5),
    ),
    const SizedBox(height: TeraSpacing.lg),
    FilledButton(onPressed: widget.onDone, child: const Text('Done')),
  ];

  Widget _errorPanel(String message) => Container(
    decoration: systemFlagDecoration(),
    padding: const EdgeInsets.all(TeraSpacing.md),
    child: Text(message, style: const TextStyle(color: TeraColors.ink, height: 1.4)),
  );
}
