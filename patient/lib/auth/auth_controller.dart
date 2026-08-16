/// Session state for the app.
///
/// A [ChangeNotifier] rather than a state-management package: the app has one piece of global
/// state — whether someone is signed in — and adding a dependency to hold one boolean and a
/// [StoredSession] would be a worse trade than the twenty lines below.
library;

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../notifications/notification_service.dart';
import 'local_wipe.dart';
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

  /// Sign out, and leave nothing behind.
  ///
  /// [wipeLocalPatientData] is the whole point: `_api.signOut()` clears the four token keys, and
  /// for a long time that was all a sign-out did. The rest of the handset's copy of the patient —
  /// their date of birth, sex, height, weight, reported conditions, pregnancy and arrhythmia
  /// answers, medication list, device eligibility, calibration anchor and any capture left
  /// mid-flow — survived it untouched and was there for whoever signed in next. A phone gets
  /// shared far more often than an account does.
  ///
  /// It runs here rather than in the Profile screen's button so that every route out of a session
  /// goes through it, and it runs *after* the network call so a failed revoke cannot skip it.
  Future<void> signOut({bool wipeLocalData = true}) async {
    try {
      await _api.signOut();
    } finally {
      // Local removal is not conditional on the network. A revoke that never reached the server
      // still has to leave this handset clean.
      if (wipeLocalData) {
        await wipeLocalPatientData(
          // The daily reminder is scheduled with the system, not just stored. Removing the
          // preference without cancelling it leaves it firing on the next person's lock screen.
          cancelScheduledNotifications: NotificationService().cancelAll,
        );
      }
      _session = null;
      _status = AuthStatus.signedOut;
      _error = null;
      notifyListeners();
    }
  }

  /// Called by [ApiClient] when a refresh fails and the session cannot be recovered.
  ///
  /// **Deliberately does not wipe.** This is an expired or rejected token, not a patient leaving
  /// the device: the same person is about to sign back in, and throwing away their onboarding,
  /// device eligibility and profile over a token that lapsed overnight would make a transient
  /// failure cost a full re-setup. The wipe belongs to [signOut], which is someone saying they
  /// are done with this handset.
  void onSessionLost() {
    _session = null;
    _status = AuthStatus.signedOut;
    _error = 'Your session has ended. Please sign in again.';
    notifyListeners();
  }
}
