/// The results view.
///
/// Every row is either a measured value or the words "not measured" with a reason. There is no
/// blank cell, because a blank invites the reader to fill it in from context (invariant 9).
library;

import 'package:flutter/material.dart';

import '../profile_result.dart';
import '../upload.dart';

class ResultView extends StatelessWidget {
  const ResultView({
    super.key,
    required this.result,
    required this.log,
    required this.onRunAgain,
    required this.onCopyJson,
    required this.onCopyMarkdown,
    required this.onSaveToFile,
  });

  final ProfileResult result;
  final List<String> log;
  final VoidCallback onRunAgain;
  final VoidCallback onCopyJson;
  final VoidCallback onCopyMarkdown;
  final VoidCallback onSaveToFile;

  @override
  Widget build(BuildContext context) {
    final handset = result.handset;

    return ListView(
      children: [
        Text(
          handset.isOk ? handset.requireValue.displayName : 'Unknown handset',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        if (handset.isOk)
          Text(
            'Android ${handset.requireValue.androidRelease} · '
            'SDK ${handset.requireValue.sdkInt} · ${handset.requireValue.device}',
            style: const TextStyle(color: Color(0xFF456990)),
          ),
        const SizedBox(height: 16),

        _Section(
          title: 'Accelerometer',
          rows: [
            _Row(
              'Achieved rate',
              result.accelerometerRate.describe(
                (r) => '${r.meanRateHz.toStringAsFixed(1)} Hz',
              ),
            ),
            _Row(
              'Inter-sample interval SD',
              result.accelerometerRate.describe(
                (r) => '${r.intervalSdMillis.toStringAsFixed(3)} ms',
              ),
            ),
            _Row(
              'Estimated dropped samples',
              result.accelerometerRate.describe(
                (r) => '${r.estimatedDroppedSamples} '
                    '(${r.droppedPercent.toStringAsFixed(1)}%)',
              ),
            ),
            _Row(
              'Above 200 Hz delivered',
              result.elevatedRateAchieved.describe((v) => v ? 'yes' : 'no'),
            ),
            _Row(
              'HIGH_SAMPLING_RATE_SENSORS',
              result.accelerometerInfo.describe(
                (a) => a.highSamplingRatePermissionGranted ? 'granted' : 'not granted',
              ),
            ),
            _Row(
              'Advertised ceiling',
              result.accelerometerInfo.describe(
                (a) => '${a.advertisedMaxHz.toStringAsFixed(1)} Hz',
              ),
            ),
          ],
          note: 'The achieved rate is measured from sample timestamps, not from the rate '
              'requested.',
        ),

        _Section(
          title: 'Camera characteristics',
          rows: [
            _Row(
              'Hardware level',
              result.cameraCapabilities.describe((c) => c.hardwareLevel.name),
            ),
            _Row(
              'MANUAL_SENSOR',
              result.cameraCapabilities.describe((c) => c.hasManualSensor ? 'present' : 'absent'),
            ),
            _Row(
              'Timestamp source',
              result.cameraCapabilities.describe((c) => c.timestampSource.name),
            ),
            _Row(
              'Torch',
              result.cameraCapabilities.describe((c) => c.hasFlash ? 'available' : 'absent'),
            ),
            _Row(
              'Smallest YUV size',
              result.cameraCapabilities.describe(
                (c) => c.smallestYuvSize?.toString() ?? 'none offered',
              ),
            ),
            _Row(
              'Min frame duration there',
              result.cameraCapabilities.describe((c) {
                final s = c.smallestYuvSize;
                return s == null
                    ? 'no YUV size offered'
                    : '${(s.minFrameDurationNanos / 1e6).toStringAsFixed(2)} ms '
                          '(ceiling ${s.maxFps.toStringAsFixed(1)} fps)';
              }),
            ),
            _Row(
              'YUV sizes offered',
              result.cameraCapabilities.describe((c) => '${c.yuvSizes.length}'),
            ),
          ],
          note: 'Timestamp source "realtime" means camera and accelerometer share a clock. '
              '"unknown" means they must be aligned through an inferred offset.',
        ),

        _CameraRunSection(run: result.coldRun, title: 'Camera run — cold'),
        _CameraRunSection(run: result.warmRun, title: 'Camera run — warm (no cool-down)'),

        if (result.coldRun.rate.isOk && result.warmRun.rate.isOk)
          _Section(
            title: 'Thermal effect',
            rows: [
              _Row(
                'Sustained rate, cold to warm',
                '${result.coldRun.rate.requireValue.meanRateHz.toStringAsFixed(1)} fps → '
                    '${result.warmRun.rate.requireValue.meanRateHz.toStringAsFixed(1)} fps',
              ),
              _Row(
                'Change',
                () {
                  final cold = result.coldRun.rate.requireValue.meanRateHz;
                  final warm = result.warmRun.rate.requireValue.meanRateHz;
                  if (cold <= 0) return 'not computable';
                  return '${(100 * (warm - cold) / cold).toStringAsFixed(1)}%';
                }(),
              ),
            ],
            note: 'The warm run follows the cold one immediately. A device that holds its rate '
                'here is one that can sustain a real capture.',
          ),

        // Placed directly above the offset figures, because if the bases disagree those
        // figures describe nothing.
        _Section(
          title: 'Clock basis — verified, not assumed',
          rows: [
            _Row(
              'Camera declares',
              result.clockBasis.camera?.declaredSource?.name ?? 'not verified',
            ),
            _Row(
              'Camera timestamps behave like',
              result.clockBasis.camera?.observed.name ?? 'not verified',
            ),
            _Row(
              'Accelerometer timestamps behave like',
              result.clockBasis.accelerometer?.observed.name ?? 'not verified',
            ),
            _Row(
              'Deep-sleep separation',
              result.clockBasis.camera == null
                  ? 'not verified'
                  : '${result.clockBasis.camera!.clockSeparationMillis.toStringAsFixed(0)} ms',
            ),
            _Row(
              'Streams share a base',
              switch (result.clockBasis.sharedBasis) {
                true => 'yes',
                false => 'NO — see below',
                null => 'could not be established',
              },
            ),
          ],
          note: result.clockBasis.verdict,
          emphasised: result.clockBasis.needsAttention,
        ),

        _Section(
          title: 'Clock offset stability',
          rows: [
            for (var i = 0; i < result.clockOffsets.length; i++)
              _Row(
                'Run ${i + 1}',
                '${result.clockOffsets[i].offsetMillis.toStringAsFixed(3)} ms'
                    '${result.clockOffsets[i].uptimeHasNanosecondPrecision ? '' : ' (ms precision)'}',
              ),
            _Row(
              'Spread (max − min)',
              result.clockOffsetStatistics.describe(
                (s) => '${s.spreadMillis.toStringAsFixed(3)} ms',
              ),
            ),
            _Row(
              'Standard deviation',
              result.clockOffsetStatistics.describe(
                (s) => '${s.sdMillis.toStringAsFixed(3)} ms',
              ),
            ),
          ],
          note: 'What matters is stability, not the absolute value: a constant offset is '
              'absorbed by personal calibration.',
        ),

        const SizedBox(height: 8),
        _ExportBar(
          onCopyJson: onCopyJson,
          onCopyMarkdown: onCopyMarkdown,
          onSaveToFile: onSaveToFile,
        ),
        const SizedBox(height: 8),
        UploadCard(result: result),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: onRunAgain, child: const Text('Run again')),
        const SizedBox(height: 24),

        ExpansionTile(
          title: const Text('Full run log'),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                log.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _CameraRunSection extends StatelessWidget {
  const _CameraRunSection({required this.run, required this.title});

  final CameraRunResult run;
  final String title;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: title,
      rows: [
        _Row(
          'Achieved frame rate',
          run.rate.describe((r) => '${r.meanRateHz.toStringAsFixed(1)} fps'),
        ),
        _Row(
          'Dropped frames',
          run.rate.describe(
            (r) => '${r.estimatedDroppedSamples} (${r.droppedPercent.toStringAsFixed(1)}%)',
          ),
        ),
        _Row(
          '99th percentile interval',
          run.rate.describe((r) => '${r.p99IntervalMillis.toStringAsFixed(1)} ms'),
        ),
        _Row('Frames captured', run.rate.describe((r) => '${r.sampleCount}')),
        _Row('Size opened', run.yuvSize.describe((s) => s.toString())),
        _Row(
          'ROI processing, mean',
          run.processing.describe((p) => '${p.meanMillis.toStringAsFixed(3)} ms'),
        ),
        _Row(
          'ROI processing, p99',
          run.processing.describe((p) => '${p.p99Millis.toStringAsFixed(3)} ms'),
        ),
        _Row(
          'Thermal before → after',
          '${run.thermalBefore.describe((c) => c.thermalStatus.name)} → '
              '${run.thermalAfter.describe((c) => c.thermalStatus.name)}',
        ),
        _Row(
          'Battery before → after',
          '${run.thermalBefore.describe((c) => c.batteryPercent == null ? 'unreported' : '${c.batteryPercent}%')} → '
              '${run.thermalAfter.describe((c) => c.batteryPercent == null ? 'unreported' : '${c.batteryPercent}%')}',
        ),
      ],
    );
  }
}

class _ExportBar extends StatelessWidget {
  const _ExportBar({
    required this.onCopyJson,
    required this.onCopyMarkdown,
    required this.onSaveToFile,
  });

  final VoidCallback onCopyJson;
  final VoidCallback onCopyMarkdown;
  final VoidCallback onSaveToFile;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton(onPressed: onCopyMarkdown, child: const Text('Copy markdown row')),
        OutlinedButton(onPressed: onCopyJson, child: const Text('Copy JSON')),
        OutlinedButton(onPressed: onSaveToFile, child: const Text('Save JSON to file')),
      ],
    );
  }
}

class _Row {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  /// A row whose value begins with "not measured" is a failure, and is styled as one.
  bool get isFailure => value.startsWith('not measured');
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.rows,
    this.note,
    this.emphasised = false,
  });

  final String title;
  final List<_Row> rows;
  final String? note;

  /// Draws a heavier border. Reserved for findings that should stop the operator — a *system*
  /// state, never a physiological one, and expressed as weight rather than colour.
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: emphasised ? const Color(0xFF12304A) : const Color(0xFFB8C1C9),
          width: emphasised ? 3 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: Color(0xFF12304A),
            ),
          ),
          const SizedBox(height: 12),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(
                      row.label,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF456990)),
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: Text(
                      row.value,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: row.isFailure ? FontWeight.w400 : FontWeight.w600,
                        fontStyle: row.isFailure ? FontStyle.italic : FontStyle.normal,
                        color: row.isFailure
                            ? const Color(0xFF456990)
                            : const Color(0xFF12304A),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (note != null) ...[
            const SizedBox(height: 12),
            Text(
              note!,
              style: const TextStyle(fontSize: 11, height: 1.4, color: Color(0xFF364F65)),
            ),
          ],
        ],
      ),
    );
  }
}
