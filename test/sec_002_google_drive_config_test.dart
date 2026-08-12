import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/google_drive_service.dart';

void main() {
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
}
