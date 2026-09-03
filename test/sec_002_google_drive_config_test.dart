import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/google_drive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.vbook.reader/app_identity');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'Drive access without GOOGLE_DRIVE_API_KEY returns config error',
    () async {
      await expectLater(
        GoogleDriveService.fetchStoriesFromFolders(['drive-folder-id']),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('GOOGLE_DRIVE_API_KEY'),
          ),
        ),
      );
    },
  );

  test(
    'Drive reads Android build configuration when dart-define is absent',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var requestedNativeKey = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getGoogleDriveApiKey') {
              requestedNativeKey = true;
              return 'configured-value';
            }
            return null;
          });

      await expectLater(
        GoogleDriveService.fetchStoriesFromFolders(const []),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Vui lòng nhập ít nhất một link'),
          ),
        ),
      );
      expect(requestedNativeKey, isTrue);
    },
  );
}
