import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/auth_controller.dart';
import 'package:tera_patient/auth/token_store.dart';

AuthController _controller(
  MockClient httpClient, {
  InMemoryTokenStore? store,
}) {
  late AuthController auth;
  final api = ApiClient(
    baseUrl: 'http://test',
    tokenStore: store ?? InMemoryTokenStore(),
    httpClient: httpClient,
    onSessionLost: () => auth.onSessionLost(),
  );
  return auth = AuthController(api: api);
}

void main() {
  test('starts in checking, then resolves to signed out with no stored session', () async {
    final auth = _controller(MockClient((_) async => http.Response('', 404)));

    expect(auth.status, AuthStatus.checking);
    await auth.restore();
    expect(auth.status, AuthStatus.signedOut);
  });

  test('a stored session is restored without a network call', () async {
    // Blocking launch on a round trip would leave a patient watching a spinner on a bad
    // connection; the first real request refreshes or fails instead.
    var called = false;
    final store = InMemoryTokenStore()
      ..write(const StoredSession(
        accessToken: 'a',
        refreshToken: 'r',
        role: 'patient',
        subject: 'p@test.invalid',
      ));

    final auth = _controller(
      MockClient((_) async {
        called = true;
        return http.Response('', 200);
      }),
      store: store,
    );
    await auth.restore();

    expect(auth.status, AuthStatus.signedIn);
    expect(called, isFalse);
  });

  test('a successful sign-in moves to signed in', () async {
    final auth = _controller(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'access_token': 'a',
            'refresh_token': 'r',
            'role': 'patient',
            'expires_in': 900,
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    expect(await auth.signIn(username: 'p@test.invalid', password: 'pw'), isTrue);
    expect(auth.status, AuthStatus.signedIn);
    expect(auth.error, isNull);
  });

  test('a rejected sign-in surfaces a message that does not reveal whether the account exists',
      () async {
    final auth = _controller(
      MockClient((_) async => http.Response('{"detail":"x"}', 401)),
    );

    expect(await auth.signIn(username: 'p@test.invalid', password: 'bad'), isFalse);
    expect(auth.status, isNot(AuthStatus.signedIn));
    expect(auth.error, 'Incorrect username or password.');
  });

  test('an unreachable backend is reported as a connection problem, not bad credentials',
      () async {
    final auth = _controller(MockClient((_) async => throw Exception('offline')));

    expect(await auth.signIn(username: 'p@test.invalid', password: 'pw'), isFalse);
    expect(auth.error, contains('Could not reach Tera'));
  });

  test('sign out clears the session', () async {
    final store = InMemoryTokenStore()
      ..write(const StoredSession(
        accessToken: 'a',
        refreshToken: 'r',
        role: 'patient',
        subject: 'p@test.invalid',
      ));
    final auth = _controller(
      MockClient((_) async => http.Response('', 204)),
      store: store,
    );
    await auth.restore();

    await auth.signOut();

    expect(auth.status, AuthStatus.signedOut);
    expect(auth.session, isNull);
    expect(await store.read(), isNull);
  });

  test('an unrecoverable refresh returns the app to sign-in with an explanation', () async {
    final store = InMemoryTokenStore()
      ..write(const StoredSession(
        accessToken: 'a',
        refreshToken: 'r',
        role: 'patient',
        subject: 'p@test.invalid',
      ));

    late AuthController auth;
    final api = ApiClient(
      baseUrl: 'http://test',
      tokenStore: store,
      httpClient: MockClient((_) async => http.Response('{"detail":"revoked"}', 401)),
      onSessionLost: () => auth.onSessionLost(),
    );
    auth = AuthController(api: api);
    await auth.restore();
    expect(auth.status, AuthStatus.signedIn);

    await expectLater(api.getJson('/v1/episodes'), throwsA(isA<SessionExpiredException>()));

    expect(auth.status, AuthStatus.signedOut);
    expect(auth.error, contains('session has ended'));
  });
}
