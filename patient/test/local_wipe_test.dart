/// Signing out has to actually remove the patient from the handset.
///
/// The regression this file exists for: `ApiClient.signOut` cleared four token keys and nothing
/// else, so the next person to sign in on the same phone inherited the previous patient's date of
/// birth, sex, height, weight, conditions, pregnancy and arrhythmia answers, medication list,
/// device eligibility, calibration anchor and any capture left mid-flow.
///
/// The last test is the one that matters most. A hand-maintained list of stores is exactly what
/// went stale — `DeviceProfileStore` has claimed in its own docstring to be "cleared on sign-out"
/// since the day it was written, and nothing ever cleared it. So the registry is checked against
/// the source rather than against someone remembering.
library;

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/auth/local_wipe.dart';

/// An in-memory stand-in for the Keystore, which a unit test has no access to.
class _FakeSecureStorage implements FlutterSecureStorage {
  _FakeSecureStorage(this.values);

  final Map<String, String> values;
  final List<String> deleted = [];

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deleted.add(key);
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used by the wipe');
}

/// Every `.dart` file under `lib/`.
List<File> _libSources() {
  final lib = Directory('lib');
  return lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

void main() {
  test('every registered secure key is deleted', () async {
    final storage = _FakeSecureStorage({for (final k in teraSecureKeys) k: 'x'});

    await wipeLocalPatientData(
      storage: storage,
      documentsDirectory: Directory.systemTemp.createTempSync('tera_wipe'),
    );

    expect(storage.values, isEmpty);
    expect(storage.deleted, containsAll(teraSecureKeys));
  });

  test('the health record goes, not just the tokens', () async {
    // Named individually because these are the ones whose absence was the leak: the tokens were
    // always cleared, and clearing them is what made the leak invisible.
    final storage = _FakeSecureStorage({
      'tera.access_token': 'x',
      'tera.phr_profile': '{"date_of_birth":"1990-01-01"}',
      'tera.context_intake': '{"pregnant":true}',
      'tera.app_flow': '{}',
      'tera.device_profile_id.v2': 'dp-1',
    });

    await wipeLocalPatientData(
      storage: storage,
      documentsDirectory: Directory.systemTemp.createTempSync('tera_wipe'),
    );

    expect(storage.values.containsKey('tera.phr_profile'), isFalse);
    expect(storage.values.containsKey('tera.context_intake'), isFalse);
    expect(storage.values.containsKey('tera.app_flow'), isFalse);
    expect(storage.values.containsKey('tera.device_profile_id.v2'), isFalse);
  });

  test('local files go too', () async {
    final dir = Directory.systemTemp.createTempSync('tera_wipe');
    for (final name in teraLocalFiles) {
      File('${dir.path}/$name').writeAsStringSync('{}');
    }

    await wipeLocalPatientData(
      storage: _FakeSecureStorage({}),
      documentsDirectory: dir,
    );

    for (final name in teraLocalFiles) {
      expect(
        File('${dir.path}/$name').existsSync(),
        isFalse,
        reason: '$name survived the wipe',
      );
    }
  });

  test('a store that cannot be reached does not abort the rest', () async {
    // A missing file is the ordinary case — most wipes run with no capture in progress — and it
    // must not stop the secure keys being removed.
    final storage = _FakeSecureStorage({for (final k in teraSecureKeys) k: 'x'});

    await wipeLocalPatientData(
      storage: storage,
      documentsDirectory: Directory('${Directory.systemTemp.path}/tera_absent_dir'),
    );

    expect(storage.values, isEmpty);
  });

  group('the registry is checked against the source, not against memory', () {
    test('no secure key in lib/ is missing from teraSecureKeys', () {
      // Two shapes, because a storage key in this codebase is written one of two ways: declared
      // as a `static const ...Key` constant, or passed inline to `key:`. Matching every
      // `'tera.…'` literal instead would sweep up things that are not storage at all — the first
      // run of this test caught `developer.log(name: 'tera.thresholds')`, a logger channel.
      //
      // A store that names its key some third way slips past this. That is a known limit and an
      // acceptable one: the point is to catch the ordinary case, which is the case that leaked.
      final patterns = [
        RegExp(r"static const \w*[Kk]ey\w* = '(tera\.[A-Za-z0-9_.]+)'"),
        RegExp(r"key: '(tera\.[A-Za-z0-9_.]+)'"),
      ];
      final found = <String, String>{};
      for (final file in _libSources()) {
        final source = file.readAsStringSync();
        for (final pattern in patterns) {
          for (final match in pattern.allMatches(source)) {
            found[match.group(1)!] = file.path;
          }
        }
      }

      expect(found, isNotEmpty, reason: 'the scan found nothing — the pattern is wrong');

      final missing = {
        for (final entry in found.entries)
          if (!teraSecureKeys.contains(entry.key)) entry.key: entry.value,
      };
      expect(
        missing,
        isEmpty,
        reason:
            'these storage keys are written by the app but survive a sign-out. Add them to '
            'teraSecureKeys in lib/auth/local_wipe.dart: $missing',
      );
    });

    test('no local file in lib/ is missing from teraLocalFiles', () {
      final pattern = RegExp(r"static const _fileName = '(tera_[A-Za-z0-9_]+\.json)'");
      final found = <String, String>{};
      for (final file in _libSources()) {
        for (final match in pattern.allMatches(file.readAsStringSync())) {
          found[match.group(1)!] = file.path;
        }
      }

      expect(found, isNotEmpty, reason: 'the scan found nothing — the pattern is wrong');

      final missing = {
        for (final entry in found.entries)
          if (!teraLocalFiles.contains(entry.key)) entry.key: entry.value,
      };
      expect(
        missing,
        isEmpty,
        reason:
            'these files are written by the app but survive a sign-out. Add them to '
            'teraLocalFiles in lib/auth/local_wipe.dart: $missing',
      );
    });
  });
}
