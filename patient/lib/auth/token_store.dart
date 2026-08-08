/// Where the tokens live on the handset.
///
/// **`flutter_secure_storage`, never `SharedPreferences`.** SharedPreferences is an XML file in
/// the app's data directory, readable by anything with root, by any backup that includes app
/// data, and by anyone with physical access to an unlocked or unencrypted device. A refresh
/// token there is a fortnight of access to a patient's health record sitting in plain text.
///
/// `flutter_secure_storage` puts the value behind the Android Keystore, so the key material
/// never leaves hardware-backed storage on devices that have it and the ciphertext is useless
/// without the device.
///
/// `encryptedSharedPreferences: true` is set deliberately: without it the plugin falls back to
/// plain SharedPreferences on some Android versions, which is exactly the failure this class
/// exists to avoid.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';

@immutable
class StoredSession {
  const StoredSession({
    required this.accessToken,
    required this.refreshToken,
    required this.role,
    required this.subject,
  });

  final String accessToken;
  final String refreshToken;
  final String role;
  final String subject;

  StoredSession copyWith({String? accessToken, String? refreshToken}) => StoredSession(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    role: role,
    subject: subject,
  );
}

/// The contract, so tests and the UI do not need a real keystore.
abstract class TokenStore {
  Future<StoredSession?> read();
  Future<void> write(StoredSession session);
  Future<void> clear();
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  final FlutterSecureStorage _storage;

  static const _accessKey = 'tera.access_token';
  static const _refreshKey = 'tera.refresh_token';
  static const _roleKey = 'tera.role';
  static const _subjectKey = 'tera.subject';

  @override
  Future<StoredSession?> read() async {
    final access = await _storage.read(key: _accessKey);
    final refresh = await _storage.read(key: _refreshKey);
    final role = await _storage.read(key: _roleKey);
    final subject = await _storage.read(key: _subjectKey);

    if (access == null || refresh == null || role == null || subject == null) {
      // A partially written session is not a session. Returning null sends the user to sign
      // in again, which is the only useful thing to do with it.
      return null;
    }
    return StoredSession(accessToken: access, refreshToken: refresh, role: role, subject: subject);
  }

  @override
  Future<void> write(StoredSession session) async {
    await _storage.write(key: _accessKey, value: session.accessToken);
    await _storage.write(key: _refreshKey, value: session.refreshToken);
    await _storage.write(key: _roleKey, value: session.role);
    await _storage.write(key: _subjectKey, value: session.subject);
  }

  @override
  Future<void> clear() async {
    // Deleted key by key rather than deleteAll(): the app may later store non-session values,
    // and a sign-out that wipes unrelated state is a surprise.
    for (final key in [_accessKey, _refreshKey, _roleKey, _subjectKey]) {
      await _storage.delete(key: key);
    }
  }
}

/// In-memory store for tests and for the widget preview. Never used in a release build.
class InMemoryTokenStore implements TokenStore {
  StoredSession? _session;

  @override
  Future<StoredSession?> read() async => _session;

  @override
  Future<void> write(StoredSession session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}
