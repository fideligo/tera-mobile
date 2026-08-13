/// Where the user is in the one-time setup, and what the splash needs to route on.
///
/// AUTH-00 asks three questions in order: authenticated, device checked, onboarding complete. This
/// holds the last two. Auth is [AuthController]'s and stays there.
///
/// Persisted on the handset in the same secure storage as the tokens and the context intake, for
/// the same reason: onboarding answers are health data, and a half-finished onboarding that resets
/// on every launch is worse than no onboarding.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';

import 'check_session.dart';
import 'routes.dart';

/// Section 7's three onboarding screens, plus the terminal state.
enum OnboardingStep {
  aboutYou('about_you', Routes.onboardingAboutYou),
  safety('safety', Routes.onboardingSafety),
  healthContext('health_context', Routes.onboardingHealthContext),
  complete('complete', Routes.home);

  const OnboardingStep(this.wireValue, this.route);

  final String wireValue;

  /// Where an unfinished onboarding resumes. AUTH-00: "authenticated + onboarding incomplete →
  /// unfinished onboarding step" — the step itself, not the first one.
  final String route;

  static OnboardingStep fromWire(String? v) => OnboardingStep.values.firstWhere(
    (s) => s.wireValue == v,
    orElse: () => aboutYou,
  );

  OnboardingStep? get next => switch (this) {
    aboutYou => safety,
    safety => healthContext,
    healthContext => complete,
    complete => null,
  };
}

@immutable
class AppFlowState {
  const AppFlowState({
    this.deviceEligibility,
    this.onboardingStep = OnboardingStep.aboutYou,
    this.reference = const BpReferenceStatus(),
  });

  /// Null means DEV-01 has never run on this handset. Device eligibility comes **before** PHR
  /// onboarding, per section 6.
  final DeviceEligibility? deviceEligibility;

  final OnboardingStep onboardingStep;
  final BpReferenceStatus reference;

  bool get deviceChecked => deviceEligibility != null;
  bool get onboardingComplete => onboardingStep == OnboardingStep.complete;

  /// AUTH-00's routing table, for an authenticated user. The unauthenticated branch is the
  /// caller's, because this object knows nothing about tokens.
  String get resumeRoute {
    if (!deviceChecked) return Routes.devicePermission;
    if (!onboardingComplete) return onboardingStep.route;
    return Routes.home;
  }

  AppFlowState copyWith({
    DeviceEligibility? deviceEligibility,
    OnboardingStep? onboardingStep,
    BpReferenceStatus? reference,
  }) => AppFlowState(
    deviceEligibility: deviceEligibility ?? this.deviceEligibility,
    onboardingStep: onboardingStep ?? this.onboardingStep,
    reference: reference ?? this.reference,
  );

  Map<String, dynamic> toJson() => {
    'device_eligibility': deviceEligibility?.name,
    'onboarding_step': onboardingStep.wireValue,
    'bp_reference_taken_at': reference.currentReferenceTakenAt
        ?.toUtc()
        .toIso8601String(),
    'last_sensor_check_at': reference.lastSuccessfulSensorCheckAt
        ?.toUtc()
        .toIso8601String(),
    'force_reference_refresh': reference.forceReferenceRefresh,
  };

  static AppFlowState fromJson(Map<String, dynamic> json) {
    DateTime? at(String key) {
      final v = json[key] as String?;
      return v == null ? null : DateTime.parse(v);
    }

    final eligibility = json['device_eligibility'] as String?;
    return AppFlowState(
      deviceEligibility: eligibility == null
          ? null
          : DeviceEligibility.values.firstWhere(
              (e) => e.name == eligibility,
              orElse: () => DeviceEligibility.notEligible,
            ),
      onboardingStep: OnboardingStep.fromWire(
        json['onboarding_step'] as String?,
      ),
      reference: BpReferenceStatus(
        currentReferenceTakenAt: at('bp_reference_taken_at'),
        lastSuccessfulSensorCheckAt: at('last_sensor_check_at'),
        forceReferenceRefresh:
            json['force_reference_refresh'] as bool? ?? false,
      ),
    );
  }
}

abstract class AppFlowStore {
  Future<AppFlowState> read();
  Future<void> write(AppFlowState state);
  Future<void> clear();
}

class SecureAppFlowStore implements AppFlowStore {
  SecureAppFlowStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  final FlutterSecureStorage _storage;

  static const _key = 'tera.app_flow';

  @override
  Future<AppFlowState> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return const AppFlowState();
    try {
      return AppFlowState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      // A blob that no longer parses is treated as a fresh install rather than crashing on
      // launch. The user redoes setup, which is recoverable; a crash loop is not.
      return const AppFlowState();
    }
  }

  @override
  Future<void> write(AppFlowState state) =>
      _storage.write(key: _key, value: jsonEncode(state.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class InMemoryAppFlowStore implements AppFlowStore {
  InMemoryAppFlowStore([this._state = const AppFlowState()]);

  AppFlowState _state;

  @override
  Future<AppFlowState> read() async => _state;

  @override
  Future<void> write(AppFlowState state) async => _state = state;

  @override
  Future<void> clear() async => _state = const AppFlowState();
}
