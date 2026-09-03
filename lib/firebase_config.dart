import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class VBookFirebaseConfig {
  static const String _firebaseApiKey = String.fromEnvironment(
    'FIREBASE_API_KEY',
  );
  static const String _firebaseAndroidApiKey = String.fromEnvironment(
    'FIREBASE_ANDROID_API_KEY',
  );
  static const String _firebaseAppId = String.fromEnvironment(
    'FIREBASE_APP_ID',
  );
  static const String _googleAppId = String.fromEnvironment('GOOGLE_APP_ID');
  static const String _firebaseMessagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const String _gcmSenderId = String.fromEnvironment('GCM_SENDER_ID');
  static const String _firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
  );
  static const String _gcloudProject = String.fromEnvironment('GCLOUD_PROJECT');
  static const String authDomain = String.fromEnvironment(
    'FIREBASE_AUTH_DOMAIN',
  );
  static const String storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
  );
  static const String measurementId = String.fromEnvironment(
    'FIREBASE_MEASUREMENT_ID',
  );
  static const String iosBundleId = String.fromEnvironment(
    'FIREBASE_IOS_BUNDLE_ID',
  );

  static String get apiKey =>
      _firstNonEmpty([_firebaseApiKey, _firebaseAndroidApiKey]);
  static String get appId => _firstNonEmpty([_firebaseAppId, _googleAppId]);
  static String get messagingSenderId =>
      _firstNonEmpty([_firebaseMessagingSenderId, _gcmSenderId]);
  static String get projectId =>
      _firstNonEmpty([_firebaseProjectId, _gcloudProject]);

  static List<String> get missingRequiredKeys {
    final missing = <String>[];
    if (apiKey.isEmpty) missing.add('FIREBASE_API_KEY');
    if (appId.isEmpty) missing.add('FIREBASE_APP_ID');
    if (messagingSenderId.isEmpty) {
      missing.add('FIREBASE_MESSAGING_SENDER_ID');
    }
    if (projectId.isEmpty) missing.add('FIREBASE_PROJECT_ID');
    return missing;
  }

  static bool get isConfigured => missingRequiredKeys.isEmpty;

  static String get configurationHelp {
    final missing = missingRequiredKeys;
    if (missing.isEmpty) return 'Firebase config is present.';
    return 'Missing Firebase configuration values: ${missing.join(', ')}. '
        'Android builds load them from the process environment or local .env; '
        'other platforms must use --dart-define-from-file=.env.';
  }

  static FirebaseOptions get currentPlatform {
    if (!isConfigured) {
      throw StateError(configurationHelp);
    }

    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: messagingSenderId,
      projectId: projectId,
      authDomain: authDomain.isEmpty ? null : authDomain,
      storageBucket: storageBucket.isEmpty ? null : storageBucket,
      measurementId: kIsWeb || defaultTargetPlatform == TargetPlatform.android
          ? (measurementId.isEmpty ? null : measurementId)
          : null,
      iosBundleId: iosBundleId.isEmpty ? null : iosBundleId,
    );
  }

  static String _firstNonEmpty(List<String> values) {
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }
}
