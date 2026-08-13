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
import 'tokens.dart';

class InsightScreen extends StatefulWidget {
  const InsightScreen({
    super.key,
    required this.api,
    required this.sessionId,
    this.uncalibratedDemo = false,
  });

  final ApiClient api;

  /// Null when the check produced no session — BP-only, or a submission that never landed.
  final String? sessionId;

  /// BPREF-01 was skipped for this session (the no-cuff demo bypass). The backend's own
  /// confidence gating runs regardless; this only adds a standing warning above whatever it
  /// decides, so the missing reference is never silently absent from the screen a patient reads.
  final bool uncalibratedDemo;

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
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text('Insight', style: TextStyle(color: Color(0xFF1E293B), fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF1E293B)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  children: [
                    if (error != null) ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(12)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _contraindicated ? 'Tera cannot produce a trend' : 'Could not load',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
                            ),
                            const SizedBox(height: 8),
                            Text(error, style: const TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                    ] else if (insight == null) ...[
                      const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
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
                                      'Uncalibrated estimate',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: TeraColors.ink,
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
                      // 23.1 Hero Result
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4)),
                          ],
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const Text(
                              'BP-RELATED TREND',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF64748B), letterSpacing: 1.2),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              insight['hero_result'] as String? ?? 'No result',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF0F172A), height: 1.2),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),
                      // 23.3 What This Means
                      if (insight['what_this_means'] != null && (insight['what_this_means'] as String).isNotEmpty) ...[
                        const Text('What this means', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Text(
                            insight['what_this_means'] as String,
                            style: const TextStyle(fontSize: 15, color: Color(0xFF334155), height: 1.5),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],

                      // 23.4 Your Next Best Step
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF), // Light blue
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFBFDBFE)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.directions_walk, color: Color(0xFF2563EB), size: 20),
                                SizedBox(width: 8),
                                Text(
                                  'Your next best step',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF1E40AF)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              insight['next_best_step'] as String? ?? 'Keep monitoring your blood pressure as usual.',
                              style: const TextStyle(fontSize: 15, color: Color(0xFF1E3A8A), height: 1.5, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),

                      if (insight['personalized_intervention'] != null && (insight['personalized_intervention'] as String).isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0FDF4),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFBBF7D0)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.favorite, size: 20, color: Color(0xFF16A34A)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Intervention', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF166534))),
                                    const SizedBox(height: 4),
                                    Text(
                                      insight['personalized_intervention'] as String,
                                      style: const TextStyle(fontSize: 14, color: Color(0xFF15803D), height: 1.4),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => TeraFlow.toHome(context),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0F172A),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Done', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
