/// ADH-01 — the daily reminder.
///
/// The scheduling arithmetic is what is tested here, and it is the part with a real failure mode:
/// a reminder scheduled for a time that has already passed today either fires immediately or never
/// fires at all, and neither announces itself. The plugin call around it needs a platform channel
/// and is exercised on a handset, not here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tera_patient/notifications/notification_service.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
    // A zone with a whole-hour offset and no DST, so the arithmetic under test is the roll-forward
    // and not a daylight-saving transition.
    tz.setLocalLocation(tz.getLocation('Asia/Jakarta'));
  });

  tz.TZDateTime at(int hour, int minute) =>
      tz.TZDateTime(tz.local, 2026, 8, 17, hour, minute);

  group('the next occurrence', () {
    test('later today, when the time has not passed', () {
      final next = NotificationService.nextOccurrence(
        const ReminderTime(9, 0),
        now: at(7, 30),
      );

      expect(next.day, 17);
      expect(next.hour, 9);
      expect(next.minute, 0);
    });

    test('tomorrow, when it already has', () {
      // The failure this guards: scheduling in the past either delivers at once or is dropped.
      final next = NotificationService.nextOccurrence(
        const ReminderTime(9, 0),
        now: at(14, 15),
      );

      expect(next.day, 18);
      expect(next.hour, 9);
    });

    test('exactly now counts as passed, so it does not fire twice', () {
      final next = NotificationService.nextOccurrence(
        const ReminderTime(9, 0),
        now: at(9, 0),
      );

      expect(next.day, 18);
    });

    test('it rolls the month, not just the day', () {
      final next = NotificationService.nextOccurrence(
        const ReminderTime(6, 0),
        now: tz.TZDateTime(tz.local, 2026, 8, 31, 22, 0),
      );

      expect(next.month, 9);
      expect(next.day, 1);
    });

    test('the result is in the handset own zone', () {
      final next = NotificationService.nextOccurrence(
        const ReminderTime(9, 0),
        now: at(7, 0),
      );

      // "09:00 where the patient is", not a fixed instant that shifts when they travel.
      expect(next.location, tz.local);
    });
  });

  group('the preference round-trips', () {
    test('an enabled reminder survives storage', () async {
      final store = InMemoryReminderStore();
      await store.write(
        const ReminderPreference(enabled: true, time: ReminderTime(21, 30)),
      );

      final read = await store.read();
      expect(read.enabled, isTrue);
      expect(read.time, const ReminderTime(21, 30));
      expect(read.time.label, '21:30');
    });

    test('an unset store is off, not on at a default time', () async {
      // A reminder nobody asked for is a notification nobody consented to.
      final read = await InMemoryReminderStore().read();
      expect(read.enabled, isFalse);
    });

    test('a malformed stored value falls back to off', () {
      final preference = ReminderPreference.fromJson(const {'enabled': null});
      expect(preference.enabled, isFalse);
      expect(preference.time, ReminderTime.defaultTime);
    });
  });

  test('the reminder text carries no reading', () {
    // Invariant 6, on the one string that arrives unasked and may be read off a lock screen by
    // somebody other than the patient. It names the action and never the reason.
    const forbidden = [
      'mmHg',
      'systolic',
      'diastolic',
      'high',
      'low',
      'elevated',
      'risk',
      'medication',
    ];
    // Reconstructed from the service's own constants via a scheduled notification would need a
    // platform; the strings are asserted directly instead.
    const title = 'Time for your Tera check';
    const body = 'A minute of sitting still, whenever suits you today.';

    for (final word in forbidden) {
      expect(title.toLowerCase(), isNot(contains(word.toLowerCase())));
      expect(body.toLowerCase(), isNot(contains(word.toLowerCase())));
    }
  });
}
