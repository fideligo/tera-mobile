/// The profiler's only screen (BUILD_SPEC 6.2).
///
/// A Run button, a live progress log, then a results view. Export as JSON and as a
/// copy-paste-ready markdown table row, so results from several handsets can go straight into
/// the proposal.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../export.dart';
import '../profile_result.dart';
import '../profile_runner.dart';
import '../smoke_report.dart';
import 'result_view.dart';

class ProfilerPage extends StatefulWidget {
  const ProfilerPage({super.key});

  @override
  State<ProfilerPage> createState() => _ProfilerPageState();
}

class _ProfilerPageState extends State<ProfilerPage> {
  final List<String> _log = [];
  final ScrollController _logScroll = ScrollController();
  final ProfileRunner _runner = ProfileRunner();

  bool _running = false;
  ProfileResult? _result;
  SmokeReport? _smoke;

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  void _append(String message) {
    if (!mounted) return;
    setState(() => _log.add(message));
    // Keep the newest line visible; an operator watching a three-minute run should not have to
    // scroll to see where it has got to.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _result = null;
      _smoke = null;
      _log.clear();
    });

    try {
      final result = await _runner.run(onProgress: _append);
      if (mounted) setState(() => _result = result);
    } on Object catch (e) {
      _append('Run aborted: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runSmoke() async {
    setState(() {
      _running = true;
      _result = null;
      _smoke = null;
      _log.clear();
    });

    try {
      final report = await _runner.runSmoke(onProgress: _append);
      if (mounted) setState(() => _smoke = report);
    } on Object catch (e) {
      _append('Smoke test aborted: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tera device profiler'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(28),
          child: Padding(
            padding: EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Measured values only. A measurement that fails is reported as failed.',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (result == null) ...[
                _Instructions(running: _running),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _running ? null : _run,
                  child: Text(_running ? 'Running…' : 'Run profile (about 3½ minutes)'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _running ? null : _runSmoke,
                  child: const Text('Smoke test (about 20 s) — no publishable numbers'),
                ),
                if (_smoke != null) ...[
                  const SizedBox(height: 12),
                  _SmokeSummary(report: _smoke!, onCopy: () => _copy(_smoke!.toPlainText(), 'Smoke report')),
                ],
                const SizedBox(height: 16),
                Expanded(child: _LogView(log: _log, controller: _logScroll)),
              ] else ...[
                Expanded(
                  child: ResultView(
                    result: result,
                    log: _log,
                    onRunAgain: _run,
                    onCopyJson: () => _copy(exportJson(result), 'JSON'),
                    onCopyMarkdown: () => _copy(exportMarkdownRow(result), 'markdown row'),
                    onSaveToFile: () => _save(result),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what copied to the clipboard')),
    );
  }

  Future<void> _save(ProfileResult result) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await saveResultToFile(result);
      messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }
}

class _Instructions extends StatelessWidget {
  const _Instructions({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFF456990)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Before you start',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          const SizedBox(height: 8),
          const Text(
            '1. Put the handset on a table for the accelerometer run (60 s).\n'
            '2. When the camera runs begin, cover the rear lens completely with a fingertip. '
            'The torch will come on.\n'
            '3. The second camera run starts immediately after the first, with no cool-down. '
            'That is deliberate — it is how thermal throttling shows up.\n'
            '4. Do not lock the screen or switch apps. Either one stops the camera.',
            style: TextStyle(height: 1.5),
          ),
          if (running) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}

/// Per-stage pass/fail for a smoke run.
///
/// Numbers appear in the detail lines because that is what makes the debugging loop fast, and
/// the header says plainly that they are not measurement data. There is no export button beyond
/// copying the text — a [SmokeReport] has no route to a markdown row by construction.
class _SmokeSummary extends StatelessWidget {
  const _SmokeSummary({required this.report, required this.onCopy});

  final SmokeReport report;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: const Color(0xFF12304A),
          width: report.allPassed ? 1 : 3,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SMOKE TEST — NOT MEASUREMENT DATA',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: Color(0xFF12304A),
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Five seconds is not a sustained-rate measurement. These figures must not go into '
            'the device eligibility table.',
            style: TextStyle(fontSize: 11, height: 1.35, color: Color(0xFF364F65)),
          ),
          const Divider(height: 16),
          for (final stage in report.stages)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      stage.passed ? 'PASS' : 'FAIL',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: stage.passed
                            ? const Color(0xFF456990)
                            : const Color(0xFF12304A),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          stage.name,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: stage.passed ? FontWeight.w500 : FontWeight.w700,
                          ),
                        ),
                        Text(
                          stage.detail,
                          style: const TextStyle(
                            fontSize: 11,
                            height: 1.3,
                            color: Color(0xFF364F65),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 16),
          Text(
            report.summary,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onCopy, child: const Text('Copy smoke report')),
        ],
      ),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.log, required this.controller});

  final List<String> log;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    if (log.isEmpty) {
      return const Center(
        child: Text(
          'The live log appears here.',
          style: TextStyle(color: Color(0xFF456990)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFB8C1C9)),
      ),
      child: ListView.builder(
        controller: controller,
        itemCount: log.length,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: SelectableText(
            log[index],
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.35,
              color: Color(0xFF12304A),
            ),
          ),
        ),
      ),
    );
  }
}
