/// The result of one profiling run.
///
/// Every field is a [Measurement]: either something the handset actually reported, or a stated
/// reason it could not be measured. BUILD_SPEC 6.2 — "Report measured values only. If a
/// measurement fails, say so — never substitute an estimate or a plausible-looking number."
///
/// There is deliberately no `verdict` field. The profiler measures; the backend grades. Keeping
/// the eligibility bands in one place (`backend/app/config.py`) means a threshold change does
/// not require reflashing eight handsets.
library;

import 'package:tera_capture/tera_capture.dart';

/// One camera run — cold or warm.
class CameraRunResult {
  const CameraRunResult({
    required this.label,
    required this.rate,
    required this.processing,
    required this.thermalBefore,
    required this.thermalAfter,
    required this.yuvSize,
  });

  final String label;
  final Measurement<RateStatistics> rate;
  final Measurement<DurationStatistics> processing;
  final Measurement<DeviceContext> thermalBefore;
  final Measurement<DeviceContext> thermalAfter;
  final Measurement<YuvSize> yuvSize;

  Map<String, Object?> toJson() => {
    'label': label,
    'rate': rate.toJson((r) => r.toJson()),
    'roi_processing': processing.toJson((p) => p.toJson()),
    'thermal_before': thermalBefore.toJson((c) => c.toJson()),
    'thermal_after': thermalAfter.toJson((c) => c.toJson()),
    'yuv_size': yuvSize.toJson((s) => s.toJson()),
  };
}

class ProfileResult {
  const ProfileResult({
    required this.startedAt,
    required this.completedAt,
    required this.profilerVersion,
    required this.handset,
    required this.accelerometerInfo,
    required this.accelerometerRate,
    required this.accelerometerThermalBefore,
    required this.accelerometerThermalAfter,
    required this.cameraCapabilities,
    required this.coldRun,
    required this.warmRun,
    required this.clockOffsets,
    required this.clockOffsetStatistics,
    required this.clockBasis,
  });

  final DateTime startedAt;
  final DateTime completedAt;
  final String profilerVersion;

  final Measurement<HandsetInfo> handset;
  final Measurement<AccelerometerInfo> accelerometerInfo;
  final Measurement<RateStatistics> accelerometerRate;
  final Measurement<DeviceContext> accelerometerThermalBefore;
  final Measurement<DeviceContext> accelerometerThermalAfter;

  final Measurement<CameraCapabilities> cameraCapabilities;
  final CameraRunResult coldRun;
  final CameraRunResult warmRun;

  final List<ClockOffsetSample> clockOffsets;
  final Measurement<OffsetStatistics> clockOffsetStatistics;

  /// Whether the two streams' timestamps are in the base each claims, and — the figure that
  /// decides whether a transit time is measurable at all — whether they share one.
  final CrossStreamClockCheck clockBasis;

  /// Whether sensor delivery above 200 Hz was actually achieved (BUILD_SPEC 6.2).
  ///
  /// Distinct from *holding* the permission — the point of the question is what arrived, not
  /// what was allowed.
  Measurement<bool> get elevatedRateAchieved => accelerometerRate.map((r) => r.meanRateHz > 200.0);

  Map<String, Object?> toJson() => {
    'schema': 'tera.device_profile/1',
    'profiler_version': profilerVersion,
    'started_at': startedAt.toUtc().toIso8601String(),
    'completed_at': completedAt.toUtc().toIso8601String(),
    'measured_values_only': true,
    'handset': handset.toJson((h) => h.toJson()),
    'accelerometer': {
      'info': accelerometerInfo.toJson((a) => a.toJson()),
      'achieved_rate': accelerometerRate.toJson((r) => r.toJson()),
      'elevated_rate_above_200hz_achieved': elevatedRateAchieved.toJson((v) => v),
      'thermal_before': accelerometerThermalBefore.toJson((c) => c.toJson()),
      'thermal_after': accelerometerThermalAfter.toJson((c) => c.toJson()),
    },
    'camera': {
      'capabilities': cameraCapabilities.toJson((c) => c.toJson()),
      'cold_run': coldRun.toJson(),
      'warm_run': warmRun.toJson(),
    },
    'clock': {
      'samples': clockOffsets.map((s) => s.toJson()).toList(),
      'statistics': clockOffsetStatistics.toJson((s) => s.toJson()),
      'note':
          'Stability matters, not the absolute value: a constant offset is absorbed by '
          'personal calibration.',
      // Measured, not assumed. A declared timestamp source that the timestamps do not obey
      // would make every offset figure above meaningless.
      'basis_verification': clockBasis.toJson(),
    },
  };

  /// A markdown table row, ready to paste into the proposal's device eligibility table
  /// (BUILD_SPEC 6.2).
  ///
  /// A failed measurement renders as `not measured`, never as a blank cell that a reader might
  /// fill in from context.
  String toMarkdownRow() {
    String cell(Measurement<dynamic> m, String Function(dynamic) format) =>
        m.isOk ? format(m.requireValue) : 'not measured';

    final device = handset.isOk ? handset.requireValue.displayName : 'unknown handset';
    final os = handset.isOk ? 'Android ${handset.requireValue.androidRelease}' : '—';

    return '| $device '
        '| $os '
        '| ${cell(accelerometerRate, (r) => '${r.meanRateHz.toStringAsFixed(1)} Hz')} '
        '| ${cell(accelerometerRate, (r) => '${r.intervalSdMillis.toStringAsFixed(2)} ms')} '
        '| ${cell(coldRun.rate, (r) => '${r.meanRateHz.toStringAsFixed(1)} fps')} '
        '| ${cell(warmRun.rate, (r) => '${r.meanRateHz.toStringAsFixed(1)} fps')} '
        '| ${cell(warmRun.rate, (r) => '${r.droppedPercent.toStringAsFixed(1)}%')} '
        '| ${cell(warmRun.rate, (r) => '${r.p99IntervalMillis.toStringAsFixed(1)} ms')} '
        '| ${cell(cameraCapabilities, (c) => c.hardwareLevel.name)} '
        '| ${cell(cameraCapabilities, (c) => c.hasManualSensor ? 'yes' : 'no')} '
        '| ${cell(cameraCapabilities, (c) => c.timestampSource.name)} '
        '| ${cell(clockOffsetStatistics, (s) => '${s.sdMillis.toStringAsFixed(2)} ms')} '
        '| ${_sharedBasisCell()} '
        '| ${cell(coldRun.processing, (p) => '${p.meanMillis.toStringAsFixed(2)} ms')} '
        '| ${cell(coldRun.processing, (p) => '${p.p99Millis.toStringAsFixed(2)} ms')} |';
  }

  /// The shared-basis column.
  ///
  /// It is in the table because a handset whose two streams sit in different time bases cannot
  /// produce a transit time at all, whatever its frame rate says — and that is not visible in
  /// any other column.
  String _sharedBasisCell() => switch (clockBasis.sharedBasis) {
    true => 'yes',
    false => 'NO — different bases',
    null => 'not verified',
  };

  static const String markdownHeader =
      '| Handset | OS | Accel rate | Accel jitter (SD) | Camera fps (cold) | '
      'Camera fps (warm) | Dropped (warm) | p99 interval (warm) | HW level | MANUAL_SENSOR | '
      'Timestamp source | Clock offset SD | Shared clock basis | ROI mean | ROI p99 |\n'
      '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|';

  /// The payload `POST /v1/device-profiles` expects.
  ///
  /// Returns null when a field the API requires could not be measured. The API has no way to
  /// express "not measured" for these, and sending a placeholder would put an invented number
  /// into the clinical record — invariant 9. Better to refuse the upload and say why.
  Map<String, Object?>? toDeviceProfilePayload(String patientId) {
    if (!handset.isOk ||
        !accelerometerRate.isOk ||
        !warmRun.rate.isOk ||
        !cameraCapabilities.isOk ||
        !clockOffsetStatistics.isOk) {
      return null;
    }

    final capabilities = cameraCapabilities.requireValue;
    return {
      'patient_id': patientId,
      'model': handset.requireValue.displayName,
      'os_version': 'Android ${handset.requireValue.androidRelease}',
      'accel_rate_hz': accelerometerRate.requireValue.meanRateHz,
      // The warm figure, deliberately. A device is only as good as its sustained rate, and a
      // cold number describes the first minute of the first session of the day.
      'camera_fps': warmRun.rate.requireValue.meanRateHz,
      'camera_hw_level': switch (capabilities.hardwareLevel) {
        CameraHardwareLevel.level3 => 'level_3',
        final level => level.name,
      },
      'manual_sensor': capabilities.hasManualSensor,
      'timestamp_source': capabilities.timestampSource.name,
      'clock_offset_sd_ms': clockOffsetStatistics.requireValue.sdMillis,
      'synthetic': false,
    };
  }

  /// Why [toDeviceProfilePayload] refused, for display.
  String? get uploadBlockedReason {
    final missing = <String>[
      if (!handset.isOk) 'handset identity',
      if (!accelerometerRate.isOk) 'accelerometer rate',
      if (!warmRun.rate.isOk) 'warm camera rate',
      if (!cameraCapabilities.isOk) 'camera characteristics',
      if (!clockOffsetStatistics.isOk) 'clock offset stability',
    ];
    if (missing.isEmpty) return null;
    return 'Cannot upload: ${missing.join(', ')} could not be measured. '
        'The API has no way to record "not measured" for these, and sending a placeholder '
        'would put an invented number into the record.';
  }
}
