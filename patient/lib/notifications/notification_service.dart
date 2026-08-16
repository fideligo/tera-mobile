/// ADH-01 — the daily check reminder.
///
/// # Entirely on the handset
///
/// Scheduled and delivered locally. No FCM, no push token, no server round trip, and nothing about
/// this patient's routine leaving the device. Two reasons, and the second is the stronger:
///
///   * a patient is offline between checks more often than not, and a reminder that needs a server
///     is a reminder that does not arrive;
///   * a push token is an identifier held by a third party, and the message it delivers says the
///     holder is monitoring their blood pressure. That is health data in the routing metadata, not
///     just in the payload, and no amount of care with the notification text removes it.
///
/// # What it is allowed to say
///
/// A reminder, and nothing else. Invariant 6 forbids any string that states or implies a diagnosis
/// or clinical reassurance, and a notification is the one piece of copy in the product that arrives
/// unasked, out of context, on a lock screen someone else may be looking at. [_title] and [_body]
/// therefore name the action and never the reason: no numbers, no trend, no "your readings have
/// been high". Nothing here is allowed to become a channel for a result.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// When the reminder is due, as a wall-clock time on the handset.
@immutable
class ReminderTime {
  const ReminderTime(this.hour, this.minute);

  final int hour;
  final int minute;

  /// Late morning: past the resting-state advice for a first-thing check, before the day fills up.
  /// A default, not a recommendation — PRE-01 is where readiness is actually decided.
  static const ReminderTime defaultTime = ReminderTime(9, 0);

  String get label =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  Map<String, dynamic> toJson() => {'hour': hour, 'minute': minute};

  static ReminderTime fromJson(Map<String, dynamic> json) => ReminderTime(
    (json['hour'] as num?)?.toInt() ?? defaultTime.hour,
    (json['minute'] as num?)?.toInt() ?? defaultTime.minute,
  );

  @override
  bool operator ==(Object other) =>
      other is ReminderTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);
}

/// Schedules, cancels and reports the daily reminder.
///
/// Every method is best-effort and none throws. A notification is an affordance, not a clinical
/// path: a handset that refuses the permission, an OEM that kills the scheduler, a platform channel
/// missing under test — none of those is a reason to fail whatever the caller was doing. The one
/// thing this must never do is report a reminder as scheduled when it is not, which is why
/// [scheduleDaily] returns the outcome rather than void.
class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  bool _ready = false;

  /// One channel, named for what it is. Android shows this to the patient in system settings, so
  /// it has to read as something a person recognises rather than as an internal id.
  static const _channelId = 'tera.daily_check';
  static const _channelName = 'Daily check reminder';
  static const _channelDescription =
      'A once-a-day reminder to take your Tera check. Never contains a reading.';

  /// A fixed id, so scheduling again replaces the existing reminder instead of stacking a second
  /// one on top of it. A patient who changes the time twice should end up with one notification,
  /// not three.
  static const int dailyReminderId = 1001;

  static const _title = 'Time for your Tera check';
  static const _body = 'A minute of sitting still, whenever suits you today.';

  /// Prepare the plugin and the timezone database. Safe to call more than once.
  Future<bool> initialize() async {
    if (_ready) return true;
    try {
      tz_data.initializeTimeZones();
      final ok = await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _ready = ok ?? false;
      return _ready;
    } on Object catch (e) {
      debugPrint('[TERA] notifications unavailable: $e');
      return false;
    }
  }

  /// Ask for permission to post notifications.
  ///
  /// **Android 13 changed this from granted-by-default to a runtime request.** On 12 and below the
  /// platform returns null rather than true, so a null is treated as "already permitted" — reading
  /// it as a refusal would silently disable reminders on every older handset.
  Future<bool> requestPermission() async {
    if (!await initialize()) return false;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return false;
      return await android.requestNotificationsPermission() ?? true;
    } on Object catch (e) {
      debugPrint('[TERA] notification permission request failed: $e');
      return false;
    }
  }

  /// Schedule the daily reminder, replacing any existing one. Returns false when it could not be.
  Future<bool> scheduleDaily(ReminderTime at) async {
    if (!await initialize()) return false;
    try {
      await _plugin.zonedSchedule(
        dailyReminderId,
        _title,
        _body,
        _nextOccurrence(at),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
        // Inexact on purpose. `exactAllowWhileIdle` needs SCHEDULE_EXACT_ALARM, which Android 14
        // restricts to alarms and timers a user set explicitly and which Play reviews as such — a
        // health reminder does not qualify, and a few minutes of drift costs nothing here.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        // Android-only app, but the parameter is required by the cross-platform signature. Wall
        // clock is the right reading either way: a daily reminder is "09:00 where the patient is",
        // not a fixed instant that drifts when they change zone.
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.wallClockTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
      return true;
    } on Object catch (e) {
      debugPrint('[TERA] could not schedule the reminder: $e');
      return false;
    }
  }

  Future<void> cancelDaily() async {
    try {
      await _plugin.cancel(dailyReminderId);
    } on Object catch (e) {
      debugPrint('[TERA] could not cancel the reminder: $e');
    }
  }

  /// Remove everything this app has scheduled. Called as part of signing out.
  Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } on Object catch (e) {
      debugPrint('[TERA] could not cancel notifications: $e');
    }
  }

  /// The next time [at] comes round, in the handset's own zone.
  ///
  /// Pure and separated so the roll-forward is testable: scheduling for a time that has already
  /// passed today has to mean tomorrow, and getting that wrong either fires immediately or silently
  /// never fires at all.
  static tz.TZDateTime nextOccurrence(ReminderTime at, {tz.TZDateTime? now}) {
    final current = now ?? tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(
      current.location,
      current.year,
      current.month,
      current.day,
      at.hour,
      at.minute,
    );
    if (!next.isAfter(current)) {
      next = next.add(const Duration(days: 1));
    }
    return next;
  }

  tz.TZDateTime _nextOccurrence(ReminderTime at) => nextOccurrence(at);
}

/// Whether the reminder is on, and when.
///
/// Held in the same Keystore-backed storage as the rest of the patient's local record, and wiped
/// with it. That is not over-caution: a reminder left scheduled after a sign-out fires "Time for
/// your Tera check" on the lock screen of whoever holds the phone next, which discloses that the
/// previous person was monitoring their blood pressure without disclosing anything about them —
/// the most confusing shape a leak can take.
@immutable
class ReminderPreference {
  const ReminderPreference({this.enabled = false, this.time = ReminderTime.defaultTime});

  final bool enabled;
  final ReminderTime time;

  Map<String, dynamic> toJson() => {'enabled': enabled, ...time.toJson()};

  static ReminderPreference fromJson(Map<String, dynamic> json) => ReminderPreference(
    enabled: json['enabled'] as bool? ?? false,
    time: ReminderTime.fromJson(json),
  );
}

abstract class ReminderStore {
  Future<ReminderPreference> read();
  Future<void> write(ReminderPreference preference);
}

class SecureReminderStore implements ReminderStore {
  SecureReminderStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  final FlutterSecureStorage _storage;

  static const _key = 'tera.reminder';

  @override
  Future<ReminderPreference> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return const ReminderPreference();
    try {
      return ReminderPreference.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return const ReminderPreference();
    }
  }

  @override
  Future<void> write(ReminderPreference preference) =>
      _storage.write(key: _key, value: jsonEncode(preference.toJson()));
}

class InMemoryReminderStore implements ReminderStore {
  InMemoryReminderStore([this._preference = const ReminderPreference()]);

  ReminderPreference _preference;

  @override
  Future<ReminderPreference> read() async => _preference;

  @override
  Future<void> write(ReminderPreference preference) async => _preference = preference;
}
