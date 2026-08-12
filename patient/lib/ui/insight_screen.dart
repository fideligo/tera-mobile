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

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../routing/app_router.dart';

class InsightScreen extends StatefulWidget {
  const InsightScreen({super.key, required this.api, required this.sessionId});

  final ApiClient api;

  /// Null when the check produced no session — BP-only, or a submission that never landed.
  final String? sessionId;

  @override
  State<InsightScreen> createState() => _InsightScreenState();
}

class _InsightScreenState extends State<InsightScreen> {
  Map<String, dynamic>? _insight;
  String? _error;
  bool _contraindicated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final id = widget.sessionId;
    if (id == null) {
      setState(() => _error = 'This check did not produce a result to explain.');
      return;
    }
    try {
      final body = await widget.api.getJson('/v1/check-sessions/$id/insight');
      if (!mounted) return;
      setState(() => _insight = body);
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

  @override
  Widget build(BuildContext context) {
    final insight = _insight;
    final error = _error;

    return Scaffold(
      appBar: AppBar(title: const Text('INS-01')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            if (error != null) ...[
              Text(_contraindicated ? 'Tera cannot produce a trend' : 'Could not load'),
              const SizedBox(height: 8),
              Text(error),
            ] else if (insight == null) ...[
              const Center(child: CircularProgressIndicator()),
            ] else ...[
              // 23.1 Hero Result.
              const Text('BP-RELATED TREND'),
              const SizedBox(height: 4),
              Text(
                insight['hero'] as String? ?? '',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (insight['reference_systolic'] != null) ...[
                const SizedBox(height: 4),
                Text(
                  'BP reference — ${insight['reference_systolic']} / '
                  '${insight['reference_diastolic']} mmHg',
                ),
              ],

              const SizedBox(height: 16),
              // 23.3 Around This Check. Chips, then the disclaimer that denies causation.
              if ((insight['context_chips'] as List?)?.isNotEmpty ?? false) ...[
                const Text('Around this check'),
                for (final chip in (insight['context_chips'] as List))
                  Text('- ${chip as String}'),
                const SizedBox(height: 4),
                Text(insight['context_disclaimer'] as String? ?? ''),
                const SizedBox(height: 16),
              ],

              // 23.4 Your Next Best Step. The prominent one.
              const Text('Your next best step'),
              const SizedBox(height: 4),
              Text(
                insight['next_best_step'] as String? ?? '',
                style: Theme.of(context).textTheme.titleMedium,
              ),

              const SizedBox(height: 24),
              Text(insight['notice'] as String? ?? ''),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => TeraFlow.toHome(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
