/// Entering a cuff reading, confirming it, and saving it.
///
/// Three stages, and the order is the safety property: **enter, confirm, save**. The submit call
/// is only reachable from the confirm stage, and the confirm stage is the only place a
/// `ConfirmedCuffReading` is constructed. A patient cannot reach the API from the keyboard.
///
/// The confirmation screen shows the numerals at display size, because the thing being confirmed
/// is the numerals and a 15pt echo of what was just typed confirms nothing. This is the one place
/// in the patient app where large numerals are correct — they are a cuff measurement, which is
/// exactly what invariant 1 reserves that treatment for.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../capture/cuff_reading.dart';
import '../capture/session_context.dart';
import 'tokens.dart';

enum _Stage { enter, confirm, saved }

class CuffReadingScreen extends StatefulWidget {
  const CuffReadingScreen({super.key, required this.api, required this.onDone});

  final ApiClient api;
  final VoidCallback onDone;

  @override
  State<CuffReadingScreen> createState() => _CuffReadingScreenState();
}

class _CuffReadingScreenState extends State<CuffReadingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _systolic = TextEditingController();
  final _diastolic = TextEditingController();
  final _pulse = TextEditingController();

  _Stage _stage = _Stage.enter;
  DraftCuffReading? _draft;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _systolic.dispose();
    _diastolic.dispose();
    _pulse.dispose();
    super.dispose();
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
            _Stage.enter => _enterStage(),
            _Stage.confirm => _confirmStage(),
            _Stage.saved => _savedStage(),
          },
        ),
      ),
    );
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
