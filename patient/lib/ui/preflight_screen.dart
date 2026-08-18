/// The last screen before a capture: silence the handset.
///
/// The reasoning for gating on the ringer rather than on the Do Not Disturb filter is in
/// `capture/preflight_check.dart`. This screen is the presentation of that check and the one
/// place a patient can act on it.
library;

import 'package:flutter/material.dart';
import 'package:sound_mode_advanced/sound_mode_advanced.dart';

import '../capture/preflight_check.dart';
import 'tokens.dart';

class PreflightScreen extends StatefulWidget {
  const PreflightScreen({super.key, required this.onReady, this.reader});

  /// Called once, when the handset is silent or the patient has confirmed an unreadable state.
  final VoidCallback onReady;

  /// Injectable for tests; the real platform read otherwise.
  final RingerModeReader? reader;

  @override
  State<PreflightScreen> createState() => _PreflightScreenState();
}

class _PreflightScreenState extends State<PreflightScreen> {
  PreflightStatus? _status;
  bool _checking = true;

  /// Set only when [PreflightStatus.unreadable] gave the patient something to tick. It is not
  /// reachable from [PreflightStatus.mayVibrate]; see `preflight_check.dart`.
  bool _acknowledged = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final status = await runPreflight(reader: widget.reader);
    if (!mounted) return;
    setState(() {
      _status = status;
      _checking = false;
      // A re-check after the patient changed the setting must not leave a tick from the previous
      // reading standing: the state it was confirming no longer exists.
      if (status != PreflightStatus.unreadable) _acknowledged = false;
    });
  }

  Future<void> _openSettings() async {
    try {
      await PermissionHandler.openDoNotDisturbSetting();
    } on Object {
      // The deep link is unavailable on this handset. The instruction above still stands and the
      // patient can reach the same control from the notification shade; failing to open Settings
      // is not a reason to take the screen down.
    }
  }

  bool get _canContinue {
    final status = _status;
    if (status == null) return false;
    return status.mayProceed || (status.needsAcknowledgement && _acknowledged);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;

    return Scaffold(
      backgroundColor: TeraColors.page,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(TeraSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: TeraSpacing.md),
              const Text(
                'Persiapan perekaman',
                style: TextStyle(
                  fontSize: TeraText.display,
                  fontWeight: FontWeight.bold,
                  color: TeraColors.ink,
                ),
              ),
              const SizedBox(height: TeraSpacing.md),
              const Text(
                'Mohon aktifkan mode Jangan Ganggu (Do Not Disturb) / Silent agar getaran '
                'notifikasi tidak merusak sinyal jantung.',
                style: TextStyle(
                  fontSize: TeraText.body,
                  color: TeraColors.neutral700,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: TeraSpacing.lg),
              if (_checking)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: TeraSpacing.lg),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (status != null)
                _StatusCard(status: status),
              const SizedBox(height: TeraSpacing.md),
              if (!_checking && status == PreflightStatus.unreadable)
                CheckboxListTile(
                  value: _acknowledged,
                  onChanged: (v) => setState(() => _acknowledged = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: TeraColors.brand,
                  title: const Text(
                    'Saya sudah mengaktifkan mode senyap secara manual.',
                    style: TextStyle(
                      fontSize: TeraText.small,
                      color: TeraColors.ink,
                    ),
                  ),
                ),
              const Spacer(),
              if (!_checking && status == PreflightStatus.mayVibrate) ...[
                OutlinedButton(
                  onPressed: _openSettings,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TeraColors.brand,
                    side: const BorderSide(color: TeraColors.brand),
                    padding: const EdgeInsets.symmetric(
                      vertical: TeraSpacing.md,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(TeraRadius.button),
                    ),
                  ),
                  child: const Text('Buka pengaturan suara'),
                ),
                const SizedBox(height: TeraSpacing.sm),
              ],
              TextButton(
                onPressed: _checking ? null : _check,
                style: TextButton.styleFrom(foregroundColor: TeraColors.baltic),
                child: const Text('Periksa ulang'),
              ),
              const SizedBox(height: TeraSpacing.sm),
              FilledButton(
                onPressed: _canContinue ? widget.onReady : null,
                style: FilledButton.styleFrom(
                  backgroundColor: TeraColors.ink,
                  foregroundColor: TeraColors.paper,
                  disabledBackgroundColor: TeraColors.neutral300,
                  disabledForegroundColor: TeraColors.neutral500,
                  padding: const EdgeInsets.symmetric(vertical: TeraSpacing.md),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(TeraRadius.button),
                  ),
                ),
                child: const Text(
                  'Lanjutkan',
                  style: TextStyle(
                    fontSize: TeraText.body,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The reading, stated as what it means for the capture rather than as a mode name.
///
/// Plum for the blocked state, which is standing constraint 5 read literally: this is the app
/// reporting on its own readiness, not on the patient. Nothing here is differentiated by hue
/// alone — the icon and the sentence carry it.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final PreflightStatus status;

  @override
  Widget build(BuildContext context) {
    final (Color accent, IconData icon, String headline, String detail) =
        switch (status) {
          PreflightStatus.silenced => (
            TeraColors.brand,
            Icons.notifications_off_outlined,
            'Perangkat sudah senyap',
            'Notifikasi tidak akan menggetarkan ponsel selama perekaman.',
          ),
          PreflightStatus.mayVibrate => (
            TeraColors.plum,
            Icons.notifications_active_outlined,
            'Perangkat masih dapat bergetar',
            'Getaran notifikasi jauh lebih kuat daripada sinyal detak jantung yang '
                'direkam, dan tidak dapat dipisahkan setelah perekaman selesai.',
          ),
          PreflightStatus.unreadable => (
            TeraColors.baltic,
            Icons.help_outline,
            'Status suara tidak terbaca',
            'Tera tidak dapat membaca pengaturan suara di perangkat ini. Mohon periksa '
                'sendiri sebelum melanjutkan.',
          ),
        };

    return Container(
      padding: const EdgeInsets.all(TeraSpacing.md),
      decoration: BoxDecoration(
        color: TeraColors.paper,
        borderRadius: BorderRadius.circular(TeraRadius.card),
        border: Border.all(color: accent, width: 2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent),
          const SizedBox(width: TeraSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: TextStyle(
                    fontSize: TeraText.body,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
                const SizedBox(height: TeraSpacing.xs),
                Text(
                  detail,
                  style: const TextStyle(
                    fontSize: TeraText.small,
                    color: TeraColors.neutral700,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
