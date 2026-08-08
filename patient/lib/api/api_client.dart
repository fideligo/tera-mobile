/// HTTP client for the Tera backend, with automatic token refresh.
///
/// Access tokens live fifteen minutes. A capture session takes about a minute and a patient may
/// leave the app open for far longer, so a request failing with 401 mid-session is ordinary,
/// not exceptional — and it must not be what the patient sees. So a 401 triggers one refresh
/// and one retry, transparently.
///
/// Exactly one retry. A refresh that succeeds and is immediately followed by another 401 means
/// something is wrong that retrying will not fix, and a loop would hammer the backend while
/// showing the patient nothing.
///
/// Refresh is serialised through a single in-flight future: if three requests fail at once,
/// they wait on one refresh rather than each spending the refresh token. That matters more here
/// than in most apps, because the backend rotates refresh tokens and treats reuse of a rotated
/// one as theft — three parallel refreshes would revoke the family and sign the patient out.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/token_store.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// The session ended and cannot be recovered without the patient signing in again.
class SessionExpiredException extends ApiException {
  SessionExpiredException([super.message = 'Your session has ended. Please sign in again.'])
    : super(statusCode: 401);
}

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required TokenStore tokenStore,
    http.Client? httpClient,
    this.onSessionLost,
  }) : _tokens = tokenStore,
       _http = httpClient ?? http.Client();

  final String baseUrl;
  final TokenStore _tokens;
  final http.Client _http;

  /// Called when the session cannot be recovered, so the app can return to sign-in.
  final void Function()? onSessionLost;

  Future<void>? _refreshInFlight;

  // ------------------------------------------------------------------ auth

  /// Exchange credentials for tokens and store them.
  Future<StoredSession> signIn({required String username, required String password}) async {
    final response = await _http.post(
      Uri.parse('$baseUrl/v1/auth/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'username': username, 'password': password},
    );

    if (response.statusCode == 401) {
      // The backend answers identically for an unknown account and a wrong password, so this
      // message must not narrow it down either.
      throw ApiException('Incorrect username or password.', statusCode: 401);
    }
    if (response.statusCode != 200) {
      throw ApiException(
        'Sign-in failed (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final session = StoredSession(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String,
      role: body['role'] as String,
      subject: username,
    );
    await _tokens.write(session);
    return session;
  }

  /// Revoke the refresh token, then clear local state regardless of the outcome.
  ///
  /// A patient who pressed "sign out" must not remain signed in because the network was down.
  /// The token expires on its own either way.
  Future<void> signOut() async {
    final session = await _tokens.read();
    if (session != null) {
      try {
        await _http.post(
          Uri.parse('$baseUrl/v1/auth/logout'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${session.accessToken}',
          },
          body: jsonEncode({'refresh_token': session.refreshToken}),
        );
      } on Object {
        // Deliberately swallowed — see the docstring.
      }
    }
    await _tokens.clear();
  }

  Future<StoredSession?> currentSession() => _tokens.read();

  // ------------------------------------------------------------------ requests

  Future<Map<String, dynamic>> getJson(String path) async =>
      _decode(await _send((token) => _http.get(_uri(path), headers: _headers(token))));

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body, {
    Map<String, String> extraHeaders = const {},
  }) async => _decode(
    await _send(
      (token) => _http.post(
        _uri(path),
        headers: {..._headers(token), ...extraHeaders},
        body: jsonEncode(body),
      ),
    ),
  );

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> _headers(String token) => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  /// Send, and on 401 refresh once and retry once.
  Future<http.Response> _send(Future<http.Response> Function(String token) request) async {
    var session = await _tokens.read();
    if (session == null) throw SessionExpiredException('You are not signed in.');

    var response = await request(session.accessToken);
    if (response.statusCode != 401) return response;

    await _refreshOnce();

    session = await _tokens.read();
    if (session == null) throw SessionExpiredException();

    response = await request(session.accessToken);
    if (response.statusCode == 401) {
      // Refreshed successfully and still refused. Retrying again would not help.
      await _tokens.clear();
      onSessionLost?.call();
      throw SessionExpiredException();
    }
    return response;
  }

  /// Refresh, with concurrent callers sharing one attempt.
  Future<void> _refreshOnce() {
    return _refreshInFlight ??= _performRefresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<void> _performRefresh() async {
    final session = await _tokens.read();
    if (session == null) throw SessionExpiredException();

    final response = await _http.post(
      Uri.parse('$baseUrl/v1/auth/refresh'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': session.refreshToken}),
    );

    if (response.statusCode != 200) {
      // The token was expired, revoked, or already used — the backend revokes the whole
      // family on reuse. Nothing local can recover it.
      await _tokens.clear();
      onSessionLost?.call();
      throw SessionExpiredException();
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    await _tokens.write(
      session.copyWith(
        accessToken: body['access_token'] as String,
        refreshToken: body['refresh_token'] as String,
      ),
    );
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return const {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(_messageFor(response), statusCode: response.statusCode);
  }

  /// Surface the backend's own explanation where it has one — it is written for a person.
  String _messageFor(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] is String) return body['detail'] as String;
    } on Object {
      // fall through
    }
    return 'Request failed (${response.statusCode}).';
  }

  void dispose() => _http.close();
}
