import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/token_store.dart';
import 'package:tera_patient/capture/symptom_triage.dart';

/// A signed-in client. The store must hold a session or every request throws before it reaches
/// the mock, which would make the "record failed" tests pass for the wrong reason.
ApiClient _api(MockClient httpClient) => ApiClient(
  baseUrl: 'http://test',
  tokenStore: InMemoryTokenStore()
    ..write(
      const StoredSession(
        accessToken: 'a',
        refreshToken: 'r',
        role: 'patient',
        subject: 'demo.patient@tera.invalid',
      ),
    ),
  httpClient: httpClient,
  onSessionLost: () {},
);

void main() {
  group('the gate', () {
    test('nothing reported proceeds to the spot check', () {
      final decision = SymptomTriage.decide({});

      expect(decision.outcome, TriageOutcome.proceed);
      expect(decision.isEmergency, isFalse);
    });

    test('every single red flag on its own terminates the session', () {
      // No severity weighting and no combination that is safe to wave through. Invariant 7: a
      // false alarm costs a wasted trip, a false reassurance can cost much more.
      for (final symptom in RedFlagSymptom.values) {
        final decision = SymptomTriage.decide({symptom});

        expect(
          decision.outcome,
          TriageOutcome.emergency,
          reason: '${symptom.wireValue} must terminate the session',
        );
      }
    });

    test('all five together terminate the session', () {
      expect(SymptomTriage.decide(RedFlagSymptom.values.toSet()).isEmergency, isTrue);
    });

    test('the five red flags are exactly the ones invariant 8 names', () {
      expect(RedFlagSymptom.values.map((s) => s.wireValue).toSet(), {
        'chest_pain',
        'severe_breathlessness',
        'severe_headache',
        'visual_disturbance',
        'weakness_or_speech_difficulty',
      });
    });
  });

  group('the instruction does not depend on the network', () {
    test('it is a compile-time constant, available with no client at all', () {
      // The test itself is the argument: no ApiClient is constructed anywhere in this group, and
      // the decision and the words are both reachable without one.
      const instruction = emergencyInstruction;

      expect(instruction, isNotEmpty);
      expect(SymptomTriage.decide({RedFlagSymptom.chestPain}).isEmergency, isTrue);
    });

    test('it matches the backend wording verbatim', () {
      // The backend keeps a copy in app/services/language.py as ACTION_SEEK_EMERGENCY_CARE, which
      // is the record of what was shown. If that text changes, this fails and names the file.
      expect(
        emergencyInstruction,
        'Seek emergency care now. Call your local emergency number or go to an emergency '
        'department. Do not wait for a measurement.',
      );
    });

    test('it instructs and does not interpret', () {
      // Invariant 6: no diagnosis, no reassurance, no estimate of how urgent it is.
      final words = '$emergencyInstruction $emergencySupportingText'.toLowerCase();

      for (final forbidden in [
        'heart attack',
        'stroke',
        'probably',
        'likely',
        'may be nothing',
        'do not worry',
        "don't worry",
        'normal',
        'mild',
      ]) {
        expect(words, isNot(contains(forbidden)), reason: '"$forbidden" is an interpretation');
      }
    });

    test('it does not offer a measurement as an alternative to going', () {
      expect(emergencyInstruction.toLowerCase(), contains('do not wait for a measurement'));
    });
  });

  group('recording is a record, not a precondition', () {
    test('a failing API does not throw, and reports that it did not reach the server', () async {
      final recorder = RedFlagRecorder(
        api: _api(MockClient((_) async => http.Response('nope', 500))),
      );

      final ok = await recorder.record(
        episodeId: 'e1',
        symptoms: {RedFlagSymptom.chestPain},
      );

      expect(ok, isFalse);
    });

    test('a dead network does not throw either', () async {
      final recorder = RedFlagRecorder(
        api: _api(MockClient((_) async => throw http.ClientException('offline'))),
      );

      expect(
        await recorder.record(episodeId: 'e1', symptoms: {RedFlagSymptom.severeHeadache}),
        isFalse,
      );
    });

    test('a successful record reports success', () async {
      final recorder = RedFlagRecorder(
        api: _api(MockClient((_) async => http.Response(jsonEncode({'id': 'x'}), 201))),
      );

      expect(
        await recorder.record(episodeId: 'e1', symptoms: {RedFlagSymptom.chestPain}),
        isTrue,
      );
    });
  });

  group('the recorded payload', () {
    test('names the event type, the symptoms and what was shown', () async {
      Map<String, dynamic>? body;
      final recorder = RedFlagRecorder(
        api: _api(
          MockClient((request) async {
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode({'id': 'x'}), 201);
          }),
        ),
      );

      await recorder.record(
        episodeId: 'episode-1',
        symptoms: {RedFlagSymptom.chestPain, RedFlagSymptom.visualDisturbance},
        occurredAt: DateTime.utc(2026, 8, 14, 9, 30),
      );

      expect(body!['event_type'], 'red_flag');
      expect(body!['episode_id'], 'episode-1');
      expect(body!['occurred_at'], '2026-08-14T09:30:00.000Z');
      expect(body!['synthetic'], false);

      final payload = body!['payload'] as Map<String, dynamic>;
      expect(payload['symptoms'], containsAll(<String>['chest_pain', 'visual_disturbance']));
      // The record says what the patient was actually told, rather than leaving it to be
      // inferred from the event type.
      expect(payload['instruction_shown'], emergencyInstruction);
    });

    test('occurred_at is UTC even when the handset clock is local', () async {
      Map<String, dynamic>? body;
      final recorder = RedFlagRecorder(
        api: _api(
          MockClient((request) async {
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode({'id': 'x'}), 201);
          }),
        ),
      );

      final local = DateTime(2026, 8, 14, 9, 30);
      await recorder.record(
        episodeId: 'e1',
        symptoms: {RedFlagSymptom.chestPain},
        occurredAt: local,
      );

      expect(body!['occurred_at'], endsWith('Z'));
      expect(body!['occurred_at'], local.toUtc().toIso8601String());
    });
  });
}
