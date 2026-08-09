/// The terminal screen for a red-flag report.
///
/// Everything on it is a local constant. It builds and paints before any network call is made,
/// and the recording attempt that follows cannot change a pixel of it. That ordering is invariant
/// 8's requirement that this path not depend on network availability, expressed as code rather
/// than as a promise.
///
/// There is no measurement offered here, no estimate shown, and no way forward into a capture —
/// the only action is Done, which returns to the start.
library;

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../capture/session_context.dart';
import '../capture/symptom_triage.dart';
import 'tokens.dart';

class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({
    super.key,
    required this.api,
    required this.symptoms,
    required this.onDone,
  });

  final ApiClient api;
  final Set<RedFlagSymptom> symptoms;
  final VoidCallback onDone;

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen> {
  /// Whether the report reached the server. Shown as a quiet footnote, never as an error, and
  /// never as anything the patient is asked to act on.
  bool? _recorded;

  @override
  void initState() {
    super.initState();
    // After the first frame: the instruction is on screen before this starts, which is the point.
    WidgetsBinding.instance.addPostFrameCallback((_) => _recordInBackground());
  }

  Future<void> _recordInBackground() async {
    bool ok = false;
    try {
      final (:patientId, :episodeId) = await SessionContextResolver(
        api: widget.api,
      ).resolveEpisode();
      ok = await RedFlagRecorder(
        api: widget.api,
      ).record(episodeId: episodeId, symptoms: widget.symptoms);
    } on Object {
      // Including "there is no open episode" and "the account is not a patient". None of those
      // are things to raise with someone who has just reported chest pain.
      ok = false;
    }
    if (!mounted) return;
    setState(() => _recorded = ok);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // No swiping back into a measurement.
      canPop: false,
      child: Scaffold(
        appBar: AppBar(title: const Text('Stop'), automaticallyImplyLeading: false),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(TeraSpacing.md),
            children: [
              Container(
                decoration: systemFlagDecoration(),
                padding: const EdgeInsets.all(TeraSpacing.lg),
                child: const Text(
                  emergencyInstruction,
                  style: TextStyle(
                    fontSize: TeraText.section,
                    fontWeight: FontWeight.w600,
                    color: TeraColors.ink,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: TeraSpacing.lg),
              const Text(
                emergencySupportingText,
                style: TextStyle(color: TeraColors.ink, height: 1.5),
              ),

              if (widget.symptoms.isNotEmpty) ...[
                const SizedBox(height: TeraSpacing.lg),
                const Text(
                  'You reported:',
                  style: TextStyle(fontSize: TeraText.small, color: TeraColors.neutral700),
                ),
                const SizedBox(height: TeraSpacing.sm),
                for (final symptom in widget.symptoms)
                  Padding(
                    padding: const EdgeInsets.only(bottom: TeraSpacing.xs),
                    child: Text(
                      symptom.label,
                      style: const TextStyle(color: TeraColors.ink, height: 1.4),
                    ),
                  ),
              ],

              const SizedBox(height: TeraSpacing.xl),
              FilledButton(onPressed: widget.onDone, child: const Text('Done')),

              const SizedBox(height: TeraSpacing.lg),
              Text(
                switch (_recorded) {
                  null => 'Saving a note of this to your record…',
                  true => 'A note of this has been saved to your record.',
                  // Stated, not apologised for. It changes nothing about what to do.
                  false =>
                    'This phone could not reach your clinic’s record just now. That does not '
                    'change the advice above.',
                },
                style: const TextStyle(
                  fontSize: TeraText.small,
                  height: 1.5,
                  color: TeraColors.neutral700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
