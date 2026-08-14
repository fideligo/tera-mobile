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

/// Mirrors `MIN_PASSWORD_LENGTH` in `backend/app/schemas/auth.py`.
///
/// Duplicated rather than fetched: the sign-up form has to say the rule before the request is
/// made, and a client that guesses shorter turns a field error into a 422 the patient cannot act
/// on. If the backend raises its minimum, this moves with it.
const int minPasswordLength = 12;

/// Mirrors `MAX_PASSWORD_BYTES` in `backend/app/security/passwords.py` — bcrypt's own limit, in
/// **bytes**, so it is measured after UTF-8 encoding rather than in characters.
const int maxPasswordBytes = 72;

/// Mirrors the `min_length` on `RegisterPatientRequest.subject`.
const int minSubjectLength = 3;

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// The session ended and cannot be recovered without the patient signing in again.
class SessionExpiredException extends ApiException {
  SessionExpiredException([
    super.message = 'Your session has ended. Please sign in again.',
  ]) : super(statusCode: 401);
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
  Future<StoredSession> signIn({
    required String username,
    required String password,
  }) async {
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

  /// Self-registration: create the account, its patient record and its first episode.
  ///
  /// Unauthenticated, so it does not go through [_send] — there is no token to attach and a 401
  /// here would have nothing to refresh.
  ///
  /// The endpoint returns tokens with the new account, so the patient is signed in by the same
  /// round trip that created them rather than being handed back to a login form they have just
  /// filled in.
  ///
  /// `subject` is the only identifier sent. **No name is transmitted**: the backend deliberately
  /// stores a generated pseudonym and has nowhere to put a real one — see the endpoint docstring
  /// in `backend/app/api/v1/auth.py`.
  Future<StoredSession> registerPatient({
    required String subject,
    required String password,
  }) async {
    final response = await _http.post(
      Uri.parse('$baseUrl/v1/auth/register-patient'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'subject': subject, 'password': password}),
    );

    if (response.statusCode != 201) {
      throw ApiException(
        _registerMessageFor(response),
        statusCode: response.statusCode,
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final tokens = body['tokens'] as Map<String, dynamic>;
    final session = StoredSession(
      accessToken: tokens['access_token'] as String,
      refreshToken: tokens['refresh_token'] as String,
      role: tokens['role'] as String,
      subject: subject,
    );
    await _tokens.write(session);
    return session;
  }

  /// Sign-up failures, in the patient's terms.
  ///
  /// 422 is handled here rather than by [_messageFor] because FastAPI's validation `detail` is a
  /// list of field objects, not a sentence — surfacing it raw would show a patient a JSON dump.
  String _registerMessageFor(http.Response response) =>
      switch (response.statusCode) {
        409 => 'That email is already registered. Sign in instead.',
        422 =>
          'Check your details: a valid email, and a password of at least '
              '$minPasswordLength characters.',
        429 =>
          'Too many sign-up attempts from this connection. Try again later.',
        _ => _messageFor(response),
      };

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

  /// GET, with an optional per-call deadline.
  ///
  /// [timeout] exists for the insight fetch, which can wait on a third-party LLM. A screen a
  /// patient is staring at should not hang on someone else's API; past the deadline the caller
  /// shows what it already has. Omitted everywhere else, so ordinary calls keep the client's
  /// default behaviour.
  Future<Map<String, dynamic>> getJson(String path, {Duration? timeout}) async {
    final request = _send(
      (token) => _http.get(_uri(path), headers: _headers(token)),
    );
    return _decode(timeout == null ? await request : await request.timeout(timeout));
  }

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

  Future<Map<String, dynamic>> patchJson(
    String path,
    Map<String, dynamic> body, {
    Map<String, String> extraHeaders = const {},
  }) async => _decode(
    await _send(
      (token) => _http.patch(
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
  Future<http.Response> _send(
    Future<http.Response> Function(String token) request,
  ) async {
    var session = await _tokens.read();
    if (session == null)
      throw SessionExpiredException('You are not signed in.');

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
  ///
  /// **The field-level violations matter as much as the sentence.** This used to return the
  /// fallback for anything whose `detail` was not a plain String, which is exactly the shape a
  /// 422 from this API takes: the ingest route raises
  /// `HTTPException(detail={'detail': ..., 'violations': [...]})`, so FastAPI nests it as
  /// `{'detail': {'detail': ..., 'violations': [...]}}` and the String check falls straight
  /// through. Every validation failure therefore read as a bare "Request failed (422)" while the
  /// server had already said precisely which field it disliked and why.
  String _messageFor(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is! Map) return 'Request failed (${response.statusCode}).';

      // The ingest shape: detail is itself an object carrying the violations.
      final detail = body['detail'];
      final nested = detail is Map ? detail : body;
      final headline = (nested['detail'] is String)
          ? nested['detail'] as String
          : (detail is String ? detail : null);

      final violations = nested['violations'];
      if (violations is List && violations.isNotEmpty) {
        final parts = violations.map((v) {
          if (v is! Map) return v.toString();
          final field = v['field'] ?? (v['loc'] as List?)?.join('.');
          return field == null ? '${v['message'] ?? v['msg']}' : '$field: ${v['message'] ?? v['msg']}';
        }).join('; ');
        return headline == null ? parts : '$headline — $parts';
      }

      // FastAPI's own default: detail is a list of {loc, msg, type}.
      if (detail is List && detail.isNotEmpty) {
        return detail
            .map((v) => v is Map ? '${(v['loc'] as List?)?.join('.')}: ${v['msg']}' : '$v')
            .join('; ');
      }

      if (headline != null) return headline;
    } on Object {
      // fall through
    }
    return 'Request failed (${response.statusCode}).';
  }

  void dispose() => _http.close();
}
