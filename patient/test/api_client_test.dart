/// Token handling in the API client.
///
/// The behaviour that matters most is the one that is invisible when it works: a 401 partway
/// through a session has to be recovered without the patient seeing anything. And it has to be
/// recovered *once*, by *one* refresh — the backend rotates refresh tokens and treats reuse of
/// a rotated one as theft, so a client that fires three parallel refreshes signs its own user
/// out.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/token_store.dart';

const _session = StoredSession(
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  role: 'patient',
  subject: 'patient@test.invalid',
);

http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  group('sign in', () {
    test('stores the tokens it was given', () async {
      final store = InMemoryTokenStore();
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: store,
        httpClient: MockClient((request) async {
          expect(request.url.path, '/v1/auth/token');
          return _json({
            'access_token': 'a',
            'refresh_token': 'r',
            'role': 'patient',
            'expires_in': 900,
          });
        }),
      );

      await client.signIn(username: 'someone@test.invalid', password: 'pw');

      final stored = await store.read();
      expect(stored!.accessToken, 'a');
      expect(stored.refreshToken, 'r');
      expect(stored.role, 'patient');
    });

    test('a wrong password does not reveal whether the account exists', () async {
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: InMemoryTokenStore(),
        httpClient: MockClient((_) async => _json({'detail': 'x'}, 401)),
      );

      await expectLater(
        client.signIn(username: 'a@test.invalid', password: 'wrong'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'Incorrect username or password.',
          ),
        ),
      );
    });
  });

  group('transparent refresh', () {
    test('a 401 is recovered without the caller seeing it', () async {
      final store = InMemoryTokenStore()..write(_session);
      var protectedCalls = 0;

      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: store,
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/auth/refresh') {
            return _json({'access_token': 'access-2', 'refresh_token': 'refresh-2'});
          }
          protectedCalls++;
          // First attempt carries the stale token and is refused; the retry carries the new one.
          final auth = request.headers['Authorization'];
          return auth == 'Bearer access-2'
              ? _json({'ok': true})
              : _json({'detail': 'expired'}, 401);
        }),
      );

      final body = await client.getJson('/v1/episodes');

      expect(body['ok'], isTrue);
      expect(protectedCalls, 2, reason: 'expected exactly one retry');
      final stored = await store.read();
      expect(stored!.accessToken, 'access-2');
      expect(stored.refreshToken, 'refresh-2', reason: 'the rotated token must be kept');
    });

    test('concurrent 401s share one refresh', () async {
      // The backend revokes the whole family when a rotated refresh token is presented twice.
      // Three parallel refreshes would therefore sign the patient out.
      final store = InMemoryTokenStore()..write(_session);
      var refreshCalls = 0;

      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: store,
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/auth/refresh') {
            refreshCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return _json({'access_token': 'access-2', 'refresh_token': 'refresh-2'});
          }
          return request.headers['Authorization'] == 'Bearer access-2'
              ? _json({'ok': true})
              : _json({'detail': 'expired'}, 401);
        }),
      );

      await Future.wait([
        client.getJson('/v1/a'),
        client.getJson('/v1/b'),
        client.getJson('/v1/c'),
      ]);

      expect(refreshCalls, 1, reason: 'each request spent the refresh token separately');
    });

    test('it retries once and then gives up', () async {
      final store = InMemoryTokenStore()..write(_session);
      var protectedCalls = 0;

      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: store,
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/auth/refresh') {
            return _json({'access_token': 'access-2', 'refresh_token': 'refresh-2'});
          }
          protectedCalls++;
          return _json({'detail': 'still refused'}, 401);
        }),
      );

      await expectLater(client.getJson('/v1/episodes'), throwsA(isA<SessionExpiredException>()));
      expect(protectedCalls, 2, reason: 'a loop would hammer the backend showing nothing');
      expect(await store.read(), isNull, reason: 'an unusable session must not be kept');
    });

    test('a failed refresh clears the session and reports it lost', () async {
      final store = InMemoryTokenStore()..write(_session);
      var lost = false;

      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: store,
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/auth/refresh') {
            // What the backend returns when the family was revoked after a reuse.
            return _json({'detail': 'refresh token has been revoked'}, 401);
          }
          return _json({'detail': 'expired'}, 401);
        }),
        onSessionLost: () => lost = true,
      );

      await expectLater(client.getJson('/v1/episodes'), throwsA(isA<SessionExpiredException>()));
      expect(lost, isTrue, reason: 'the app has to be told to return to sign-in');
      expect(await store.read(), isNull);
    });
  });

  group('sign out', () {
    test('clears the session even when the backend is unreachable', () async {
      // Someone signing out on a shared handset must not stay signed in because the venue
      // network was down.
      final store = InMemoryTokenStore()..write(_session);
      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: store,
        httpClient: MockClient((_) async => throw const SocketExceptionStub()),
      );

      await client.signOut();

      expect(await store.read(), isNull);
    });

    test('revokes the refresh token when it can', () async {
      final store = InMemoryTokenStore()..write(_session);
      String? revoked;

      final client = ApiClient(
        baseUrl: 'http://test',
        tokenStore: store,
        httpClient: MockClient((request) async {
          revoked = (jsonDecode(request.body) as Map)['refresh_token'] as String;
          return http.Response('', 204);
        }),
      );

      await client.signOut();

      expect(revoked, 'refresh-1');
      expect(await store.read(), isNull);
    });
  });

  test('a request with no session fails immediately rather than calling the API', () async {
    var called = false;
    final client = ApiClient(
      baseUrl: 'http://test',
      tokenStore: InMemoryTokenStore(),
      httpClient: MockClient((_) async {
        called = true;
        return _json({});
      }),
    );

    await expectLater(client.getJson('/v1/episodes'), throwsA(isA<SessionExpiredException>()));
    expect(called, isFalse);
  });
}

/// Stands in for a network failure without importing dart:io into a test that does not need it.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
