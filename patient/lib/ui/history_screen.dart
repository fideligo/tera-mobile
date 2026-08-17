import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../export/pdf_export_service.dart';
import '../api/api_client.dart';
import 'tokens.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  bool _isLoading = true;
  String? _error;
  List<dynamic> _sessions = [];
  String _timeFilter = '30D';
  String _sourceFilter = 'All';

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final range = _timeFilter.toLowerCase();
      final response = await widget.api.getJson('/v1/history?range=$range');
      // `getJson` returns `Map<String, dynamic>`, so the old `response is Map ? ... : response as
      // List` had a branch the type system could already prove unreachable.
      final items = response['entries'] as List? ?? [];
      if (!mounted) return;
      setState(() {
        _sessions = items;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load history: $e';
        _isLoading = false;
      });
    }
  }

  /// The clinician-facing report, built by the shared service.
  ///
  /// This method used to compose its own document from `session['date']`, `session['subtitle']`
  /// and `session['title']` — three keys `HistoryEntryOut` has never carried — so every row of
  /// every export read "Unknown Date - Sensor Check / No details". It also put cuff readings and
  /// phone checks under one heading, which is the distinction standing constraint 1 exists to
  /// protect. Both are now `PdfExportService`'s problem, and it is tested.
  Future<void> _exportPdf() async {
    try {
      final data = buildReportData(
        entries: _sessions,
        generatedAt: DateTime.now(),
      );
      final bytes = await const PdfExportService().build(data);
      if (!mounted) return;
      final stamp = DateTime.now().toIso8601String().split('T').first;
      await Printing.sharePdf(bytes: bytes, filename: 'tera-record-$stamp.pdf');
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not build your report. $e')));
    }
  }

  List<dynamic> get _filteredSessions {
    return _sessions.where((session) {
      if (_sourceFilter == 'Phone checks') {
        if (session['entry_type'] != 'trend' &&
            session['entry_type'] != 'check' &&
            session['entry_type'] != 'rejected')
          return false;
      } else if (_sourceFilter == 'BP readings') {
        if (session['entry_type'] != 'cuff_reading') return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TeraColors.page,
      appBar: AppBar(
        title: const Text(
          'History',
          style: TextStyle(color: TeraColors.ink, fontWeight: FontWeight.bold),
        ),
        backgroundColor: TeraColors.paper,
        elevation: 0,
        iconTheme: const IconThemeData(color: TeraColors.ink),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf, color: TeraColors.ink),
            onPressed: _exportPdf,
            tooltip: 'Export to PDF',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: TeraSpacing.md),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildTimeChip(
                        '7D',
                        _timeFilter == '7d',
                        () => _updateTimeFilter('7d'),
                      ),
                      const SizedBox(width: 8),
                      _buildTimeChip(
                        '30D',
                        _timeFilter == '30d',
                        () => _updateTimeFilter('30d'),
                      ),
                      const SizedBox(width: 8),
                      _buildTimeChip(
                        '90D',
                        _timeFilter == '90d',
                        () => _updateTimeFilter('90d'),
                      ),
                      const SizedBox(width: 8),
                      _buildTimeChip(
                        'All',
                        _timeFilter == 'all',
                        () => _updateTimeFilter('all'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: TeraSpacing.md,
                  vertical: TeraSpacing.sm,
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildFilterChip(
                        'All',
                        _sourceFilter == 'All',
                        (v) => setState(() => _sourceFilter = 'All'),
                      ),
                      const SizedBox(width: 8),
                      _buildFilterChip(
                        'Phone checks',
                        _sourceFilter == 'Phone checks',
                        (v) => setState(() => _sourceFilter = 'Phone checks'),
                      ),
                      const SizedBox(width: 8),
                      _buildFilterChip(
                        'BP readings',
                        _sourceFilter == 'BP readings',
                        (v) => setState(() => _sourceFilter = 'BP readings'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  void _updateTimeFilter(String filter) {
    setState(() => _timeFilter = filter);
    _loadHistory();
  }

  Widget _buildTimeChip(String label, bool isSelected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? TeraColors.ink : TeraColors.paper,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? TeraColors.ink : TeraColors.neutral300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? TeraColors.paper : TeraColors.neutral700,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip(
    String label,
    bool isSelected,
    ValueChanged<bool> onSelected,
  ) {
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: onSelected,
      backgroundColor: TeraColors.paper,
      selectedColor: TeraColors.brand.withOpacity(0.1),
      checkmarkColor: TeraColors.brand,
      labelStyle: TextStyle(
        color: isSelected ? TeraColors.brand : TeraColors.neutral700,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TeraRadius.button),
        side: BorderSide(
          color: isSelected ? TeraColors.brand : TeraColors.neutral300,
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(TeraSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Plum, not red. A history that would not load is something the *system* failed at
              // and says nothing about the patient — which is the exact distinction plum exists
              // for, and the reason red is not in this palette.
              const Icon(Icons.error_outline, color: TeraColors.plum, size: 48),
              const SizedBox(height: TeraSpacing.md),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: TeraColors.ink),
              ),
              const SizedBox(height: TeraSpacing.md),
              OutlinedButton(
                onPressed: _loadHistory,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final items = _filteredSessions;
    if (items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 64, color: TeraColors.neutral300),
            SizedBox(height: TeraSpacing.md),
            Text(
              'No history found',
              style: TextStyle(
                color: TeraColors.neutral500,
                fontSize: TeraText.body,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(TeraSpacing.md),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: TeraSpacing.md),
      itemBuilder: (context, index) {
        final session = items[index];
        final type = session['entry_type'] as String;
        final isSensor =
            type == 'trend' || type == 'check' || type == 'rejected';
        final date = session['occurred_at'] ?? 'Unknown date';

        String title = 'Unknown check';
        String subtitle = 'Phone check';
        if (type == 'cuff_reading') {
          title =
              '${session['systolic_mmhg']} / ${session['diastolic_mmhg']} mmHg';
          subtitle = session['badge'] ?? 'Confirmed BP';
        } else if (type == 'trend' || type == 'check') {
          title = session['deviation_state'] ?? 'BP-related trend';
          subtitle = session['direction'] != null
              ? 'Trend: ${session['direction']}'
              : 'Phone check';
        } else if (type == 'rejected') {
          title = 'Measurement unsuccessful';
          subtitle = session['rejection_reason'] ?? 'Rejected';
        }

        final status = type == 'rejected' ? 'rejected' : 'completed';

        return Container(
          decoration: BoxDecoration(
            color: TeraColors.paper,
            borderRadius: BorderRadius.circular(TeraRadius.card),
            border: Border.all(color: TeraColors.neutral100),
            boxShadow: [
              BoxShadow(
                color: TeraColors.ink.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.all(TeraSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        isSensor ? Icons.sensors : Icons.favorite_border,
                        size: 20,
                        color: TeraColors.baltic,
                      ),
                      const SizedBox(width: TeraSpacing.sm),
                      Text(
                        isSensor ? 'Phone check' : 'BP reading',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: TeraColors.ink,
                          fontSize: TeraText.body,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    // **Only the refused state gets a colour.** A completed check is the ordinary
                    // outcome and is left neutral; tinting it green would make the badge a pair of
                    // verdicts — good and bad — over what is really "the capture worked" and "the
                    // capture did not". Plum marks the one the system could not use, which is the
                    // job plum has everywhere else in the app.
                    decoration: BoxDecoration(
                      color: status == 'completed'
                          ? TeraColors.neutral100
                          : TeraColors.plum.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(TeraRadius.pill),
                    ),
                    child: Text(
                      status.toString().toUpperCase(),
                      style: TextStyle(
                        fontSize: TeraText.micro,
                        fontWeight: FontWeight.bold,
                        color: status == 'completed'
                            ? TeraColors.neutral700
                            : TeraColors.plum,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: TeraSpacing.sm),
              Text(
                date.toString(),
                style: const TextStyle(
                  color: TeraColors.neutral500,
                  fontSize: TeraText.small,
                ),
              ),
              const SizedBox(height: TeraSpacing.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(TeraSpacing.md),
                decoration: BoxDecoration(
                  color: TeraColors.page,
                  borderRadius: BorderRadius.circular(TeraRadius.field),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: TeraColors.ink,
                        fontWeight: FontWeight.w600,
                        fontSize: TeraText.body,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: TeraColors.neutral700,
                        fontSize: TeraText.small,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
