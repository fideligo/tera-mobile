/// Resolving what a session is filed against.
///
/// The failure worth testing here is misfiling: attaching a spot check to a closed episode, or
/// registering a handset with numbers nobody measured. Both produce a record that looks correct.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_capture/tera_capture.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/token_store.dart';
import 'package:tera_patient/capture/device_measurement.dart';
import 'package:tera_patient/capture/session_context.dart';

const _patientId = '11111111-1111-4111-8111-111111111111';
const _openEpisode = '22222222-2222-4222-8222-222222222222';
const _closedEpisode = '33333333-3333-4333-8333-333333333333';
const _profileId = '44444444-4444-4444-8444-444444444444';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

DeviceMeasurements _measurements({
  CameraHardwareLevel level = CameraHardwareLevel.full,
}) => DeviceMeasurements(
  handset: const HandsetInfo(
    manufacturer: 'Acme',
    model: 'A1',
    device: 'a1',
    androidRelease: '14',
    sdkInt: 34,
  ),
  capabilities: CameraCapabilities(
    cameraId: '0',
    hardwareLevel: level,
    hasManualSensor: true,
    timestampSource: CameraTimestampSource.realtime,
    yuvSizes: const [],
    hasFlash: true,
    supportsAutoExposureLock: true,
    supportsAutoWhiteBalanceLock: true,
  ),
  accelRateHz: 480.0,
  cameraFps: 59.4,
  clockOffsetSdMs: 0.12,
);

Future<ApiClient> _client(
  Future<http.Response> Function(http.Request request) handler,
) async {
  final tokens = InMemoryTokenStore();
  await tokens.write(
    const StoredSession(
      accessToken: 'a',
      refreshToken: 'r',
      role: 'patient',
      subject: 'p@example.test',
    ),
  );
  return ApiClient(
    baseUrl: 'http://test',
    tokenStore: tokens,
    httpClient: MockClient(handler),
  );
}

void main() {
  group('the device profile payload', () {
    test('carries only measured values, and is never marked synthetic', () {
      final payload = _measurements().toDeviceProfilePayload(_patientId);

      expect(payload['accel_rate_hz'], 480.0);
      expect(payload['camera_fps'], 59.4);
      expect(payload['clock_offset_sd_ms'], 0.12);
      // Invariant 9: a real handset is never flagged as seeded, and a seeded one is never
      // flagged as real.
      expect(payload['synthetic'], isFalse);
      expect(payload['model'], 'Acme A1');
      expect(payload['os_version'], 'Android 14');
    });

    test('level 3 is sent as level_3, the only name that differs on the wire', () {
      final payload = _measurements(
        level: CameraHardwareLevel.level3,
      ).toDeviceProfilePayload(_patientId);

      expect(payload['camera_hw_level'], 'level_3');
    });
  });

  group('resolving a session context', () {
    test('files against the open episode, not merely the first one', () async {
      Map<String, dynamic>? submitted;
      final api = await _client((request) async {
        if (request.url.path.endsWith('/auth/me')) {
          return _json({'patient_id': _patientId});
        }
        if (request.url.path.endsWith('/episodes')) {
          return _json({
            'episodes': [
              // Closed, and listed first on purpose.
              {'episode_id': _closedEpisode, 'ended_at': '2026-01-01T00:00:00Z'},
              {'episode_id': _openEpisode, 'ended_at': null},
            ],
          });
        }
        submitted = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({'id': _profileId, 'qualified_status': 'qualified'}, 201);
      });

      final context = await SessionContextResolver(
        api: api,
        profiles: InMemoryDeviceProfileStore(),
      ).resolve(_measurements());

      expect(context.episodeId, _openEpisode);
      expect(context.deviceProfileId, _profileId);
      expect(submitted!['patient_id'], _patientId);
    });

    test('a closed episode alone is refused rather than appended to', () async {
      final api = await _client((request) async {
        if (request.url.path.endsWith('/auth/me')) {
          return _json({'patient_id': _patientId});
        }
        return _json({
          'episodes': [
            {'episode_id': _closedEpisode, 'ended_at': '2026-01-01T00:00:00Z'},
          ],
        });
      });

      expect(
        () => SessionContextResolver(
          api: api,
          profiles: InMemoryDeviceProfileStore(),
        ).resolve(_measurements()),
        throwsA(isA<SessionContextFailure>()),
      );
    });

    test('a clinician account is told why, not shown a missing episode', () async {
      final api = await _client((_) async => _json({'patient_id': null}));

      expect(
        () => SessionContextResolver(
          api: api,
          profiles: InMemoryDeviceProfileStore(),
        ).resolve(_measurements()),
        throwsA(
          isA<SessionContextFailure>().having(
            (e) => e.reason,
            'reason',
            contains('not a patient account'),
          ),
        ),
      );
    });

    test('a registered handset is reused, not registered again', () async {
      var registrations = 0;
      final api = await _client((request) async {
        if (request.url.path.endsWith('/auth/me')) {
          return _json({'patient_id': _patientId});
        }
        if (request.url.path.endsWith('/episodes')) {
          return _json({
            'episodes': [
              {'episode_id': _openEpisode, 'ended_at': null},
            ],
          });
        }
        if (request.method == 'GET') {
          return _json({'id': _profileId, 'qualified_status': 'provisional'});
        }
        registrations++;
        return _json({'id': _profileId, 'qualified_status': 'qualified'}, 201);
      });

      final store = InMemoryDeviceProfileStore()..write(_profileId);
      final context = await SessionContextResolver(
        api: api,
        profiles: store,
      ).resolve(_measurements());

      expect(registrations, 0, reason: 'one handset is one device profile');
      // The stored verdict is what counts, not the app's own grading of the same numbers.
      expect(context.qualifiedStatus, 'provisional');
    });
  });
}
