import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tera_patient/api/api_client.dart';
import 'package:tera_patient/auth/token_store.dart';
import 'package:tera_patient/capture/context_intake.dart';

ContextIntake intake({
  PregnancyAnswer pregnant = PregnancyAnswer.no,
  bool arrhythmia = false,
  DateTime? regimenChange,
  List<Medication> medications = const [],
  ClinicBloodPressure? clinicBp,
}) => ContextIntake(
  pregnant: pregnant,
  knownArrhythmia: arrhythmia,
  lastRegimenChangeDate: regimenChange,
  medications: medications,
  lastClinicBp: clinicBp,
);

void main() {
  _uploadTests();

  group('the pregnancy gate', () {
    test('yes blocks', () {
      expect(
        ContextIntakeSafety.evaluate(intake(pregnant: PregnancyAnswer.yes)),
        IntakeGate.blockedPregnancy,
      );
    });

    test('no is clear', () {
      expect(
        ContextIntakeSafety.evaluate(intake(pregnant: PregnancyAnswer.no)),
        IntakeGate.clear,
      );
    });

    test('prefer not to say does not block', () {
      // Blocking on a declined answer would make declining functionally identical to saying yes,
      // and would coerce a disclosure the patient chose not to make.
      expect(
        ContextIntakeSafety.evaluate(intake(pregnant: PregnancyAnswer.preferNotToSay)),
        IntakeGate.clear,
      );
    });

    test('trend generation is blocked when and only when pregnancy is reported', () {
      expect(
        ContextIntakeSafety.allowsTrendGeneration(intake(pregnant: PregnancyAnswer.yes)),
        isFalse,
      );
      expect(
        ContextIntakeSafety.allowsTrendGeneration(intake(pregnant: PregnancyAnswer.no)),
        isTrue,
      );
    });

    test('an unanswered intake does not block', () {
      // Deliberate: the form is not a precondition for using the app. Recorded in decisions.md.
      expect(ContextIntakeSafety.allowsTrendGeneration(null), isTrue);
    });

    test('a known arrhythmia is recorded but does not gate', () {
      // It degrades beat detection rather than invalidating the method; the signal chain's own
      // quality gate is where a capture too irregular to use gets rejected.
      expect(ContextIntakeSafety.evaluate(intake(arrhythmia: true)), IntakeGate.clear);
      expect(ContextIntakeSafety.allowsTrendGeneration(intake(arrhythmia: true)), isTrue);
    });

    test('the gate is pure — the same intake gives the same answer every time', () {
      final subject = intake(pregnant: PregnancyAnswer.yes);
      expect(
        List.generate(5, (_) => ContextIntakeSafety.evaluate(subject)),
        everyElement(IntakeGate.blockedPregnancy),
      );
    });
  });

  group('the block message', () {
    test('states the limitation and refers on', () {
      expect(pregnancyBlockMessage, contains('Method unvalidated in pregnancy'));
      expect(pregnancyBlockMessage, contains('consult your doctor'));
    });

    test('does not diagnose, estimate risk, or reassure', () {
      final words = '$pregnancyBlockTitle $pregnancyBlockMessage'.toLowerCase();
      for (final forbidden in [
        'pre-eclampsia',
        'preeclampsia',
        'dangerous',
        'probably',
        'do not worry',
        'should be fine',
        'normal',
      ]) {
        expect(words, isNot(contains(forbidden)), reason: '"$forbidden" is an interpretation');
      }
    });
  });

  group('the clinic reading reuses the cuff bounds', () {
    test('a plausible reading validates', () {
      expect(
        ClinicBloodPressure(
          systolicMmhg: 148,
          diastolicMmhg: 92,
          takenOn: DateTime.utc(2026, 7, 1),
        ).validate(),
        isEmpty,
      );
    });

    test('swapped numbers are caught', () {
      expect(
        ClinicBloodPressure(
          systolicMmhg: 80,
          diastolicMmhg: 120,
          takenOn: DateTime.utc(2026, 7, 1),
        ).validate(),
        isNotEmpty,
      );
    });

    test('an out-of-range systolic is caught', () {
      expect(
        ClinicBloodPressure(
          systolicMmhg: 400,
          diastolicMmhg: 92,
          takenOn: DateTime.utc(2026, 7, 1),
        ).validate(),
        isNotEmpty,
      );
    });
  });

  group('serialisation survives a round trip', () {
    test('every field returns intact', () {
      final original = ContextIntake(
        lastRegimenChangeDate: DateTime.utc(2026, 6, 15),
        medications: const [
          Medication(name: 'Amlodipine', dose: '5 mg once daily'),
          Medication(name: 'Losartan', dose: '50 mg'),
        ],
        pregnant: PregnancyAnswer.preferNotToSay,
        knownArrhythmia: true,
        lastClinicBp: ClinicBloodPressure(
          systolicMmhg: 148,
          diastolicMmhg: 92,
          takenOn: DateTime.utc(2026, 7, 1),
        ),
      );

      final restored = ContextIntake.fromJson(original.toJson());

      expect(restored.lastRegimenChangeDate, DateTime.utc(2026, 6, 15));
      expect(restored.medications.map((m) => m.name), ['Amlodipine', 'Losartan']);
      expect(restored.medications.first.dose, '5 mg once daily');
      expect(restored.pregnant, PregnancyAnswer.preferNotToSay);
      expect(restored.knownArrhythmia, isTrue);
      expect(restored.lastClinicBp!.systolicMmhg, 148);
      expect(restored.lastClinicBp!.takenOn, DateTime.utc(2026, 7, 1));
    });

    test('the optional fields survive being absent', () {
      final restored = ContextIntake.fromJson(intake().toJson());

      expect(restored.lastRegimenChangeDate, isNull);
      expect(restored.lastClinicBp, isNull);
      expect(restored.medications, isEmpty);
    });

    test('dates are stored in UTC', () {
      final local = DateTime(2026, 6, 15, 14, 30);
      final json = intake(regimenChange: local).toJson();

      expect(json['last_regimen_change_date'], endsWith('Z'));
      expect(json['last_regimen_change_date'], local.toUtc().toIso8601String());
    });

    test('a pregnancy answer survives the wire value exactly', () {
      for (final answer in PregnancyAnswer.values) {
        expect(PregnancyAnswer.fromWire(answer.wireValue), answer);
      }
    });
  });

  group('the store', () {
    test('round-trips an intake and clears it', () async {
      final store = InMemoryContextIntakeStore();
      expect(await store.read(), isNull);

      await store.write(intake(pregnant: PregnancyAnswer.yes));
      expect((await store.read())!.pregnant, PregnancyAnswer.yes);

      await store.clear();
      expect(await store.read(), isNull);
    });

    test('a stored block survives a reload, so the gate is not reset by restarting', () async {
      final store = InMemoryContextIntakeStore();
      await store.write(intake(pregnant: PregnancyAnswer.yes));

      expect(ContextIntakeSafety.allowsTrendGeneration(await store.read()), isFalse);
    });
  });
}

ApiClient _api(MockClient httpClient) => ApiClient(
  baseUrl: 'http://test',
  tokenStore: InMemoryTokenStore()
    ..write(
      const StoredSession(
        accessToken: 'a',
        refreshToken: 'r',
        role: 'patient',
        subject: 'someone@example.invalid',
      ),
    ),
  httpClient: httpClient,
  onSessionLost: () {},
);

void _uploadTests() {
  group('the upload', () {
    test('sends the flat wire shape the backend stores', () {
      final payload = PatientContextSubmitter.payload(
        ContextIntake(
          lastRegimenChangeDate: DateTime.utc(2026, 6, 15),
          medications: const [Medication(name: 'Amlodipine', dose: '5 mg')],
          pregnant: PregnancyAnswer.preferNotToSay,
          knownArrhythmia: true,
          lastClinicBp: ClinicBloodPressure(
            systolicMmhg: 148,
            diastolicMmhg: 92,
            takenOn: DateTime.utc(2026, 7, 1),
          ),
        ),
      );

      // Flat, not nested: the backend keeps the three clinic values in their own columns so a
      // CHECK can hold them together.
      expect(payload['last_clinic_systolic_mmhg'], 148);
      expect(payload['last_clinic_diastolic_mmhg'], 92);
      expect(payload['last_clinic_taken_on'], '2026-07-01T00:00:00.000Z');
      expect(payload.containsKey('last_clinic_bp'), isFalse);
      expect(payload['pregnant'], 'prefer_not_to_say');
      expect(payload['known_arrhythmia'], true);
      expect(payload['medications'], [
        {'name': 'Amlodipine', 'dose': '5 mg'},
      ]);
    });

    test('omits the clinic reading entirely when it was not given', () {
      final payload = PatientContextSubmitter.payload(
        const ContextIntake(pregnant: PregnancyAnswer.no, knownArrhythmia: false),
      );

      expect(payload['last_clinic_systolic_mmhg'], isNull);
      expect(payload['last_clinic_taken_on'], isNull);
      expect(payload['medications'], isEmpty);
    });

    test('drops blank medication rows the form leaves behind', () {
      final payload = PatientContextSubmitter.payload(
        const ContextIntake(
          medications: [Medication(name: '', dose: ''), Medication(name: 'Losartan', dose: '50mg')],
          pregnant: PregnancyAnswer.no,
          knownArrhythmia: false,
        ),
      );

      expect((payload['medications'] as List).length, 1);
    });

    test('posts to /v1/patient-context', () async {
      String? path;
      final ok = await PatientContextSubmitter(
        api: _api(
          MockClient((request) async {
            path = request.url.path;
            return http.Response(jsonEncode({'id': 'x'}), 201);
          }),
        ),
      ).submit(const ContextIntake(pregnant: PregnancyAnswer.no, knownArrhythmia: false));

      expect(ok, isTrue);
      expect(path, '/v1/patient-context');
    });

    test('a failure is reported and never thrown', () async {
      final submitter = PatientContextSubmitter(
        api: _api(MockClient((_) async => http.Response('nope', 500))),
      );

      expect(
        await submitter.submit(
          const ContextIntake(pregnant: PregnancyAnswer.no, knownArrhythmia: false),
        ),
        isFalse,
      );
    });

    test('a dead network does not throw either', () async {
      final submitter = PatientContextSubmitter(
        api: _api(MockClient((_) async => throw http.ClientException('offline'))),
      );

      expect(
        await submitter.submit(
          const ContextIntake(pregnant: PregnancyAnswer.yes, knownArrhythmia: false),
        ),
        isFalse,
      );
    });

    test('the gate does not depend on the upload succeeding', () async {
      // A patient who reported a contraindication is blocked whether or not the server heard.
      const blocked = ContextIntake(pregnant: PregnancyAnswer.yes, knownArrhythmia: false);
      await PatientContextSubmitter(
        api: _api(MockClient((_) async => http.Response('nope', 500))),
      ).submit(blocked);

      expect(ContextIntakeSafety.allowsTrendGeneration(blocked), isFalse);
    });
  });
}
