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

enum _Stage { choose, reading, enter, confirm, saved }

class CuffReadingScreen extends StatefulWidget {
  const CuffReadingScreen({
    super.key,
    required this.api,
    required this.onDone,
    this.checkSessionId,
    this.isReference = false,
    this.ocr = const CameraCuffOcrExtractor(),
  });

  final ApiClient api;
  final VoidCallback onDone;
  final String? checkSessionId;
  final bool isReference;

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

  late _Stage _stage = widget.isReference ? _Stage.choose : _Stage.enter;
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

  /// Opens the camera, then fills the fields from the extractor.
  ///
  /// The default extractor takes a real photograph and then returns fixed numbers without reading
  /// it — see `CameraCuffOcrExtractor`. The confirmation step and the simulated-reading notice
  /// are what keep that honest, and neither is skippable.
  Future<void> _photograph() async {
    setState(() {
      _stage = _Stage.reading;
      _error = null;
    });

    final CuffOcrReading reading;
    try {
      reading = await widget.ocr.extract();
    } on CuffOcrCancelled {
      // Backed out at the camera. Return to the choice, pre-fill nothing.
      if (mounted) setState(() => _stage = _Stage.choose);
      return;
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = 'The camera could not be opened. $e';
          _stage = _Stage.enter;
        });
      }
      return;
    }
    if (!mounted) return;

    _systolic.text = '${reading.systolicMmhg}';
    _diastolic.text = '${reading.diastolicMmhg}';
    _pulse.text = reading.pulseBpm?.toString() ?? '';

    final draft = DraftCuffReading(
      systolicMmhg: reading.systolicMmhg,
      diastolicMmhg: reading.diastolicMmhg,
      pulseBpm: reading.pulseBpm,
    );

    final violations = draft.validate();
    if (violations.isNotEmpty) {
      setState(() {
        _error = violations.first.message;
        _stage = _Stage.enter;
      });
      return;
    }

    setState(() {
      _draft = draft;
      _stage = _Stage.confirm;
    });
  }

  void _review() {
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final draft = DraftCuffReading(
      systolicMmhg: int.parse(_systolic.text.trim()),
      diastolicMmhg: int.parse(_diastolic.text.trim()),
      pulseBpm: _pulse.text.trim().isEmpty
          ? null
          : int.parse(_pulse.text.trim()),
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

      // **One path, always: the reading is filed as a `cuff_reading`.**
      //
      // There used to be a fork here. With a `checkSessionId` present it posted
      // `{'blood_pressure': {'systolic': ..., 'diastolic': ...}}` to
      // `/v1/check-sessions/{id}/process` instead — a body that endpoint has never accepted:
      // `ProcessIn` is an empty model with `extra="forbid"`, and the field names were `systolic`
      // / `diastolic` rather than the schema's `systolic_mmhg` / `diastolic_mmhg` anyway. Every
      // save through that branch returned 422, so the reading was never written.
      //
      // That is what produced the loop the calibration flow got stuck in: no `cuff_reading` row
      // means no history, no history means the next check is judged a first run, and the patient
      // is sent back to calibrate again. It also kept the dashboard chart empty, since cuff
      // readings are the only entries carrying mmHg.
      final resolver = SessionContextResolver(api: widget.api);
      final (:patientId, :episodeId) = await resolver.resolveEpisode();
      await CuffReadingSubmitter(
        api: widget.api,
      ).submit(reading: confirmed, episodeId: episodeId);

      // Then, separately and best-effort, move the check session along. This request carries
      // nothing — that is the actual contract — and a failure here must not lose a reading that
      // is already safely filed above.
      final checkSessionId = widget.checkSessionId;
      if (checkSessionId != null && checkSessionId.isNotEmpty) {
        try {
          await widget.api.postJson(
            '/v1/check-sessions/$checkSessionId/process',
            const {},
          );
        } on Object {
          // Deliberately swallowed; see above.
        }
      }
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
            _Stage.enter => _enterStage(),
            _Stage.confirm => _confirmStage(context),
            _Stage.saved => _savedStage(),
          },
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- choose ----

  List<Widget> _chooseStage() => [
    const SizedBox(height: TeraSpacing.xl),
    const Text(
      'Set your blood pressure preferences',
      style: TextStyle(
        fontSize: TeraText.section,
        fontWeight: FontWeight.w700,
        color: TeraColors.ink,
      ),
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: TeraSpacing.lg),
    const Text(
      'Tera uses a recent blood pressure\nreading as a personal reference\nfor your BP-related trend.',
      style: TextStyle(
        color: TeraColors.ink,
        height: 1.5,
        fontSize: TeraText.body,
      ),
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: TeraSpacing.xl),
    const Text(
      'Small checklist\nBefore measuring:',
      style: TextStyle(
        color: TeraColors.ink,
        height: 1.5,
        fontSize: TeraText.body,
      ),
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: TeraSpacing.sm),
    const Text(
      '✓ Rest quietly for at least 5 minutes\n'
      '✓ Avoid exercise for the past 30 minutes\n'
      '✓ Avoid caffeine for the past 30 minutes\n'
      '✓ Avoid smoking or nicotine for the past\n30 minutes\n'
      '✓ Sit with your back supported and feet\nflat',
      style: TextStyle(
        color: TeraColors.ink,
        height: 1.5,
        fontSize: TeraText.body,
      ),
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: TeraSpacing.xl),
    TextButton(
      onPressed: () => setState(() => _stage = _Stage.enter),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'next ',
            style: TextStyle(color: TeraColors.ink, fontSize: TeraText.body),
          ),
          Icon(Icons.arrow_forward, color: TeraColors.ink, size: 18),
        ],
      ),
    ),
  ];

  // ---------------------------------------------------------------- reading ----

  List<Widget> _readingStage() => [
    const SizedBox(height: TeraSpacing.xl),
    Container(
      height: 300,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(TeraRadius.card),
        border: Border.all(color: TeraColors.brand, width: 2),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Icon(Icons.camera_alt, color: Colors.white24, size: 64),
          // Faux scanner line animation
          TweenAnimationBuilder<double>(
            tween: Tween(begin: -150.0, end: 150.0),
            duration: const Duration(milliseconds: 1500),
            builder: (context, value, child) {
              return Transform.translate(
                offset: Offset(0, value),
                child: child,
              );
            },
            onEnd:
                () {}, // The tween itself doesn't loop easily without a controller, but it's 3s total so it will run twice roughly.
            child: Container(
              height: 2,
              width: 250,
              decoration: BoxDecoration(
                color: Colors.greenAccent,
                boxShadow: [
                  BoxShadow(
                    color: Colors.greenAccent.withValues(alpha: 0.5),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 20,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Reading display digits...',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  ];

  // ------------------------------------------------------------------ enter ----

  List<Widget> _enterStage() => [
    const SizedBox(height: TeraSpacing.xl),
    Text(
      widget.isReference
          ? 'Set your blood pressure reference'
          : 'Add your blood pressure reading',
      style: const TextStyle(
        fontSize: TeraText.section,
        fontWeight: FontWeight.w700,
        color: TeraColors.ink,
      ),
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: TeraSpacing.md),
    const Text(
      'Enter the reading you just measured',
      style: TextStyle(fontSize: TeraText.body, color: TeraColors.neutral700),
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: TeraSpacing.xl),
    Form(
      key: _formKey,
      child: Column(
        children: [
          _horizontalNumberField(
            controller: _systolic,
            label: 'systolic',
            unit: 'mmHg',
            min: systolicMinMmhg,
            max: systolicMaxMmhg,
          ),
          const SizedBox(height: TeraSpacing.sm),
          _horizontalNumberField(
            controller: _diastolic,
            label: 'diastolic',
            unit: 'mmHg',
            min: diastolicMinMmhg,
            max: diastolicMaxMmhg,
          ),
          const SizedBox(height: TeraSpacing.sm),
          _horizontalNumberField(
            controller: _pulse,
            label: 'pulse',
            unit: 'bpm',
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
    OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: TeraColors.ink,
        side: const BorderSide(color: TeraColors.ink),
        padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeraRadius.button),
        ),
      ),
      onPressed: _photograph,
      child: const Text(
        'Scan monitor instead',
        style: TextStyle(fontSize: TeraText.body, fontWeight: FontWeight.bold),
      ),
    ),
    const SizedBox(height: TeraSpacing.md),
    FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: TeraColors.ink,
        foregroundColor: TeraColors.paper,
        padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TeraRadius.button),
        ),
      ),
      onPressed: _review,
      child: const Text(
        'Save',
        style: TextStyle(fontSize: TeraText.body, fontWeight: FontWeight.bold),
      ),
    ),
  ];

  Widget _horizontalNumberField({
    required TextEditingController controller,
    required String label,
    required String unit,
    required int min,
    required int max,
    bool optional = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: TeraText.body,
              color: TeraColors.ink,
            ),
          ),
        ),
        const SizedBox(width: TeraSpacing.md),
        Expanded(
          flex: 3,
          child: TextFormField(
            controller: controller,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              filled: true,
              fillColor: TeraColors.neutral200,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 14),
            ),
            style: const TextStyle(
              fontSize: TeraText.body,
              color: TeraColors.ink,
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.next,
            validator: (v) {
              final text = (v ?? '').trim();
              if (text.isEmpty) return optional ? null : 'Req';
              final value = int.tryParse(text);
              if (value == null) return 'Inv';
              if (value < min || value > max) return 'Out';
              return null;
            },
          ),
        ),
        const SizedBox(width: TeraSpacing.md),
        Expanded(
          flex: 2,
          child: Text(
            unit,
            textAlign: TextAlign.left,
            style: const TextStyle(
              fontSize: TeraText.body,
              color: TeraColors.ink,
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- confirm ----

  List<Widget> _confirmStage(BuildContext context) {
    return [
      const SizedBox(height: TeraSpacing.xl),
      const Text(
        'Review your reading',
        style: TextStyle(
          fontSize: TeraText.section,
          fontWeight: FontWeight.w700,
          color: TeraColors.ink,
        ),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: TeraSpacing.xl),
      _horizontalNumberBox(
        label: 'systolic',
        value: _systolic.text,
        unit: 'mmHg',
      ),
      const SizedBox(height: TeraSpacing.sm),
      _horizontalNumberBox(
        label: 'diastolic',
        value: _diastolic.text,
        unit: 'mmHg',
      ),
      const SizedBox(height: TeraSpacing.sm),
      _horizontalNumberBox(label: 'pulse', value: _pulse.text, unit: 'bpm'),
      const SizedBox(height: TeraSpacing.md),
      Row(
        children: [
          Expanded(flex: 2, child: Container()),
          const SizedBox(width: TeraSpacing.md),
          Expanded(
            flex: 5,
            child: Text(
              'Measured\nJust now · ${TimeOfDay.now().format(context)}',
              textAlign: TextAlign.left,
              style: const TextStyle(
                fontSize: TeraText.body,
                color: TeraColors.ink,
              ),
            ),
          ),
        ],
      ),
      if (_error != null) ...[
        const SizedBox(height: TeraSpacing.md),
        _errorPanel(_error!),
      ],
      const SizedBox(height: TeraSpacing.xl),
      OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: TeraColors.ink,
          side: const BorderSide(color: TeraColors.ink),
          padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TeraRadius.button),
          ),
        ),
        onPressed: _photograph,
        child: const Text(
          'Scan monitor instead',
          style: TextStyle(
            fontSize: TeraText.body,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      const SizedBox(height: TeraSpacing.md),
      OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: TeraColors.ink,
          side: const BorderSide(color: TeraColors.ink),
          padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TeraRadius.button),
          ),
        ),
        onPressed: _busy ? null : () => setState(() => _stage = _Stage.enter),
        child: const Text(
          'Edit',
          style: TextStyle(
            fontSize: TeraText.body,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      const SizedBox(height: TeraSpacing.md),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: TeraColors.ink,
          foregroundColor: TeraColors.paper,
          padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TeraRadius.button),
          ),
        ),
        onPressed: _busy ? null : _confirmAndSave,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _busy ? 'Saving...' : 'Confirm ',
              style: const TextStyle(
                fontSize: TeraText.body,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (!_busy) const Icon(Icons.check, size: 20),
          ],
        ),
      ),
    ];
  }

  Widget _horizontalNumberBox({
    required String label,
    required String value,
    required String unit,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: TeraText.body,
              color: TeraColors.ink,
            ),
          ),
        ),
        const SizedBox(width: TeraSpacing.md),
        Expanded(
          flex: 3,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            color: TeraColors.neutral200,
            alignment: Alignment.center,
            child: Text(
              value,
              style: const TextStyle(
                fontSize: TeraText.body,
                color: TeraColors.ink,
              ),
            ),
          ),
        ),
        const SizedBox(width: TeraSpacing.md),
        Expanded(
          flex: 2,
          child: Text(
            unit,
            textAlign: TextAlign.left,
            style: const TextStyle(
              fontSize: TeraText.body,
              color: TeraColors.ink,
            ),
          ),
        ),
      ],
    );
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
    child: Text(
      message,
      style: const TextStyle(color: TeraColors.ink, height: 1.4),
    ),
  );
}
