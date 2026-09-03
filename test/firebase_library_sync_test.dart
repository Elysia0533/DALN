import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/story.dart';
import 'package:online_story_reader/services/firebase_backend_service.dart';

void main() {
  test('library sync payload does not rewrite immutable createdAt', () {
    final story = Story(
      id: 'story-1',
      title: 'Story',
      totalChapters: 12,
      savedChapterIndex: 3,
    );

    final payload = FirebaseBackendService.buildLibraryStoryPayload(story);

    expect(payload, isNot(contains('createdAt')));
    expect(payload['storyId'], story.id);
    expect(payload['story'], story.toJson());
    expect(payload['savedChapterIndex'], 3);
    expect(payload['totalChapters'], 12);
    expect(payload['scrollOffset'], 0);
    expect(payload, contains('updatedAt'));
  });

  test('valid cloud library data restores progress', () {
    final story = FirebaseBackendService.parseCloudLibraryStory({
      'story': Story(id: 'story-1', title: 'Story', totalChapters: 10).toJson(),
      'savedChapterIndex': 4,
      'totalChapters': 12,
    });

    expect(story, isNotNull);
    expect(story!.savedChapterIndex, 4);
    expect(story.totalChapters, 12);
  });

  test('malformed cloud library data is ignored', () {
    expect(
      FirebaseBackendService.parseCloudLibraryStory({
        'story': {'id': 'story-1', 'title': 'Story', 'genres': 'invalid'},
      }),
      isNull,
    );
    expect(
      FirebaseBackendService.parseCloudLibraryStory({'story': 'invalid'}),
      isNull,
    );
  });
}
