/// Session state for the app.
///
/// A [ChangeNotifier] rather than a state-management package: the app has one piece of global
/// state — whether someone is signed in — and adding a dependency to hold one boolean and a
/// [StoredSession] would be a worse trade than the twenty lines below.
library;

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import 'token_store.dart';

enum AuthStatus { checking, signedOut, signedIn, guest }

class AuthController extends ChangeNotifier {
  AuthController({required ApiClient api}) : _api = api;

  final ApiClient _api;

  AuthStatus _status = AuthStatus.checking;
  StoredSession? _session;
  String? _error;

  AuthStatus get status => _status;
  StoredSession? get session => _session;
  String? get error => _error;

  /// The authenticated client, for screens that call the API directly.
  ///
  /// Exposed rather than threaded separately through the widget tree, so there is exactly one
  /// client in the app and therefore exactly one refresh-in-flight guard.
  ApiClient get api => _api;
  bool get isSignedIn => _status == AuthStatus.signedIn;

  /// Browsing without an account. No token exists, so nothing that requires one — a check
  /// submission, History, Profile — can actually reach the backend; this flag is what lets the
  /// UI head that off with an explanation instead of a request that fails.
  bool get isGuest => _status == AuthStatus.guest;

  /// Home and the check flow read this rather than [isSignedIn] directly, so a guest reaches the
  /// same screens a signed-in patient does.
  bool get canUseApp =>
      _status == AuthStatus.signedIn || _status == AuthStatus.guest;

  /// Restore a session from secure storage at launch.
  ///
  /// A stored session is treated as valid without a round trip: the first real request will
  /// refresh or fail, and blocking the launch on a network call would leave a patient staring
  /// at a spinner on a bad connection.
  Future<void> restore() async {
    _session = await _api.currentSession();
    _status = _session == null ? AuthStatus.signedOut : AuthStatus.signedIn;
    notifyListeners();
  }

  Future<bool> signIn({
    required String username,
    required String password,
  }) async {
    _error = null;
    notifyListeners();

    try {
      _session = await _api.signIn(username: username, password: password);
      _status = AuthStatus.signedIn;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
      return false;
    } on Object {
      _error = 'Could not reach Tera. Check your connection and try again.';
      notifyListeners();
      return false;
    }
  }

  /// Create an account and hold the session it returns.
  ///
  /// Registration signs the patient in, because the endpoint mints tokens with the account. The
  /// alternative — bouncing them to the login form with the credentials they typed thirty seconds
  /// ago — is a round trip that exists only to make the app feel like a clinic system.
  Future<bool> register({
    required String subject,
    required String password,
  }) async {
    _error = null;
    notifyListeners();

    try {
      _session = await _api.registerPatient(
        subject: subject,
        password: password,
      );
      _status = AuthStatus.signedIn;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
      return false;
    } on Object {
      _error = 'Could not reach Tera. Check your connection and try again.';
      notifyListeners();
      return false;
    }
  }

  /// Skip authentication entirely.
  ///
  /// Deliberately not persisted: there is no token to store, so a relaunch finds
  /// [TokenStore] empty and lands back on [AuthStatus.signedOut] — the splash re-running AUTH-00
  /// is the correct behaviour for a guest, not a bug, since a guest has nothing to resume.
  void continueAsGuest() {
    _session = null;
    _error = null;
    _status = AuthStatus.guest;
    notifyListeners();
  }

  Future<void> signOut() async {
    await _api.signOut();
    _session = null;
    _status = AuthStatus.signedOut;
    _error = null;
    notifyListeners();
  }

  /// Called by [ApiClient] when a refresh fails and the session cannot be recovered.
  void onSessionLost() {
    _session = null;
    _status = AuthStatus.signedOut;
    _error = 'Your session has ended. Please sign in again.';
    notifyListeners();
  }
}
