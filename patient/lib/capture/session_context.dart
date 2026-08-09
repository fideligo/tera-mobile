/// Everything a session submission needs besides the signal itself.
///
/// A session payload references a patient's episode and the handset it was recorded on. Neither
/// is known to the app at sign-in: the token identifies a *user*, so the patient, the episode and
/// the device profile all have to be resolved from the API before the first capture can be sent.
///
/// Resolution is deliberately explicit rather than defaulted. There is no "pick the first
/// episode and hope" path here — if the account has no episode, or the handset has not been
/// registered, the capture is not submitted and the patient is told which of the two it was.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';

import '../api/api_client.dart';
import 'device_measurement.dart';
import 'threshold_crosscheck.dart';

@immutable
class SessionContext {
  const SessionContext({
    required this.patientId,
    required this.episodeId,
    required this.deviceProfileId,
    required this.qualifiedStatus,
  });

  final String patientId;
  final String episodeId;
  final String deviceProfileId;

  /// The backend's verdict on this handset, which is the one that counts. The app's own
  /// eligibility screen grades the same measurements, but the stored profile is what every
  /// session references.
  final String qualifiedStatus;
}

/// Raised when the context cannot be assembled. The reason is shown to the patient.
class SessionContextFailure implements Exception {
  const SessionContextFailure(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Remembers which device profile this handset registered as.
///
/// Not a secret, but it lives beside the tokens rather than in SharedPreferences: it is written
/// once at registration and read on every capture, and one storage mechanism is one thing to
/// reason about. Cleared on sign-out with the rest of the session.
abstract class DeviceProfileStore {
  Future<String?> read();
  Future<void> write(String deviceProfileId);
  Future<void> clear();
}

class SecureDeviceProfileStore implements DeviceProfileStore {
  SecureDeviceProfileStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  final FlutterSecureStorage _storage;

  static const _key = 'tera.device_profile_id';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String deviceProfileId) => _storage.write(key: _key, value: deviceProfileId);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryDeviceProfileStore implements DeviceProfileStore {
  String? _id;

  @override
  Future<String?> read() async => _id;

  @override
  Future<void> write(String deviceProfileId) async => _id = deviceProfileId;

  @override
  Future<void> clear() async => _id = null;
}

class SessionContextResolver {
  SessionContextResolver({required ApiClient api, DeviceProfileStore? profiles})
    : _api = api,
      _profiles = profiles ?? SecureDeviceProfileStore();

  final ApiClient _api;
  final DeviceProfileStore _profiles;

  /// Resolve just the patient and their open episode.
  ///
  /// Split out because a cuff reading needs an episode and nothing else. Registering a device
  /// profile to file a number the patient read off a cuff would attach a handset measurement to a
  /// record the handset did not take.
  Future<({String patientId, String episodeId})> resolveEpisode() async {
    final me = await _api.getJson('/v1/auth/me');
    final patientId = me['patient_id'] as String?;
    if (patientId == null) {
      // A clinician account has no patient record to record against. Saying so plainly beats a
      // 404 from the episode list, which would look like a missing episode.
      throw const SessionContextFailure(
        'This account is not a patient account, so it cannot record against a monitoring period.',
      );
    }

    final episodes = (await _api.getJson('/v1/episodes'))['episodes'] as List<dynamic>? ?? [];
    // The open episode, not merely the first: a closed one is a finished course of monitoring
    // and appending to it would misfile the reading.
    final open = episodes.cast<Map<String, dynamic>>().where((e) => e['ended_at'] == null);
    if (open.isEmpty) {
      throw const SessionContextFailure(
        'There is no open monitoring period on this account. Your clinic starts one before '
        'readings can be recorded.',
      );
    }
    return (patientId: patientId, episodeId: open.first['episode_id'] as String);
  }

  /// Resolve the patient, the episode and the device profile, registering the handset if it has
  /// not been registered from this app before.
  Future<SessionContext> resolve(DeviceMeasurements measurements) async {
    final (:patientId, :episodeId) = await resolveEpisode();

    final cached = await _profiles.read();
    if (cached != null) {
      final profile = await _api.getJson('/v1/device-profiles/$cached');
      // Also on the cached path: an override applied to the backend after this handset registered
      // would otherwise go unnoticed for the life of the install.
      reportThresholdCrossCheck(
        accelRateHz: measurements.accelRateHz,
        deviceProfile: profile,
      );
      return SessionContext(
        patientId: patientId,
        episodeId: episodeId,
        deviceProfileId: cached,
        qualifiedStatus: profile['qualified_status'] as String,
      );
    }

    final created = await _api.postJson(
      '/v1/device-profiles',
      measurements.toDeviceProfilePayload(patientId),
    );
    reportThresholdCrossCheck(
      accelRateHz: measurements.accelRateHz,
      deviceProfile: created,
    );
    final deviceProfileId = created['id'] as String;
    await _profiles.write(deviceProfileId);

    return SessionContext(
      patientId: patientId,
      episodeId: episodeId,
      deviceProfileId: deviceProfileId,
      qualifiedStatus: created['qualified_status'] as String,
    );
  }
}
