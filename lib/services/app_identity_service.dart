import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppIdentityService {
  static const MethodChannel _channel = MethodChannel(
    'com.vbook.reader/app_identity',
  );

  static Future<String> googleDriveApiKey() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return '';
    }

    try {
      final result = await _channel.invokeMethod<String>(
        'getGoogleDriveApiKey',
      );
      return result?.trim() ?? '';
    } on MissingPluginException {
      return '';
    } on PlatformException {
      return '';
    }
  }

  static Future<Map<String, String>> googleApiKeyRestrictionHeaders() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const {};
    }

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getGoogleApiKeyRestrictionHeaders',
      );
      if (result == null) return const {};

      final packageName = result['X-Android-Package']?.toString().trim() ?? '';
      final certSha1 = result['X-Android-Cert']?.toString().trim() ?? '';
      if (packageName.isEmpty || certSha1.isEmpty) return const {};

      return {'X-Android-Package': packageName, 'X-Android-Cert': certSha1};
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }
}
