import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/models/story.dart';
import 'package:online_story_reader/models/unified_search.dart';
import 'package:online_story_reader/services/database/database_service.dart';
import 'package:online_story_reader/services/search/local_library_search_index.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';
import 'package:online_story_reader/services/search/unified_search_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late DatabaseService database;
  late SearchIndexRepository repository;
  late LocalLibrarySearchIndex index;
  var stories = <Story>[];
  final source = AppUnifiedSearchGateway.localSource;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vbook-local-search-');
    database = DatabaseService(
      factory: databaseFactoryFfi,
      pathResolver: () async => path.join(directory.path, 'index.db'),
    );
    repository = SearchIndexRepository(database);
    stories = [];
    index = LocalLibrarySearchIndex(
      repository: repository,
      loadStories: () async => stories,
    );
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'SQL finds library items beyond lazy pages, normalizes accents and applies facets',
    () async {
      stories = [
        for (var i = 0; i < 500; i++)
          Story(
            id: 'local-$i',
            title: 'Truyện số $i',
            author: i == 400 ? 'Nguyễn Nhật Ánh' : 'Other',
            genres: i == 400 ? ['Tuổi trẻ'] : ['Other'],
          ),
      ];
      final result = await index.search(
        source,
        const UnifiedSearchQuery(
          text: 'truyen so 400',
          author: 'Nguyễn Nhật Ánh',
          genre: 'Tuổi trẻ',
        ),
        1,
      );
      expect(result.items.single.remoteId, 'local-400');
      expect(result.nextPage, isNull);
      final first = await index.search(
        source,
        const UnifiedSearchQuery(text: 'truyen'),
        1,
        pageSize: 15,
      );
      expect(first.items, hasLength(15));
      expect(first.nextPage, 2);
      final second = await index.search(
        source,
        const UnifiedSearchQuery(text: 'truyen'),
        2,
        pageSize: 15,
      );
      expect(
        first.items
            .map((r) => r.stableId)
            .toSet()
            .intersection(second.items.map((r) => r.stableId).toSet()),
        isEmpty,
      );
      expect((await index.facets()).authors, contains('Nguyễn Nhật Ánh'));
    },
  );

  test(
    'metadata updates and deletion never prune Drive or mutate original Story data',
    () async {
      await repository.upsertStories([
        SearchIndexStory(
          sourceType: 'googleDrive',
          sourceId: 'root',
          remoteId: 'drive',
          title: 'Drive book',
          mimeType: 'text/plain',
          lastIndexedAt: DateTime.utc(2026),
          metadataStatus: SearchMetadataStatus.partial,
        ),
      ]);
      stories = [
        Story(
          id: 'a',
          title: 'Old title',
          content: 'PRIVATE_BOOK_BODY',
          localPath: '/books/a.epub',
          savedChapterIndex: 17,
        ),
        Story(id: 'b', title: 'Deleted book'),
      ];
      final first = await index.search(
        source,
        const UnifiedSearchQuery(text: 'Old'),
        1,
      );
      expect(identical(first.items.single.story, stories.first), isTrue);
      expect(first.items.single.story.savedChapterIndex, 17);
      stories = [
        stories.first.copyWith(title: 'New title', savedChapterIndex: 18),
      ];
      final next = await index.search(
        source,
        const UnifiedSearchQuery(text: 'New'),
        1,
      );
      expect(next.items.single.story.savedChapterIndex, 18);
      expect(
        (await index.search(
          source,
          const UnifiedSearchQuery(text: 'Deleted'),
          1,
        )).items,
        isEmpty,
      );
      final rows = await (await database.database).query('stories');
      expect(rows, hasLength(2));
      expect(jsonEncode(rows), isNot(contains('PRIVATE_BOOK_BODY')));
      expect(jsonEncode(rows), isNot(contains('/books/a.epub')));
      stories = [stories.single.copyWith(savedChapterIndex: 19)];
      expect(
        (await index.search(
          source,
          const UnifiedSearchQuery(text: 'New'),
          1,
        )).items.single.story.savedChapterIndex,
        19,
      );
    },
  );

  test(
    'malformed or failed library loading preserves the previous index',
    () async {
      stories = [Story(id: 'a', title: 'Preserved')];
      await index.synchronize();
      stories = [Story(id: '', title: 'Invalid')];
      await expectLater(index.synchronize(), throwsFormatException);
      expect(
        (await repository.searchByKeyword(
          query: 'Preserved',
          sourceType: 'local',
        )).items,
        hasLength(1),
      );
      final failing = LocalLibrarySearchIndex(
        repository: repository,
        loadStories: () async => throw const FormatException('corrupt'),
      );
      await expectLater(failing.synchronize(), throwsFormatException);
      expect(
        (await repository.searchByKeyword(
          query: 'Preserved',
          sourceType: 'local',
        )).items,
        hasLength(1),
      );
    },
  );

  test(
    'default loader reads preferences without deleting content or triggering cover repair',
    () async {
      final saved = [
        jsonEncode(
          Story(
            id: 'saved',
            title: 'Saved book',
            content: 'BOOK_BODY',
            isLocal: true,
            fileType: 'epub',
            localPath: '/missing/book.epub',
          ).toJson(),
        ),
      ];
      SharedPreferences.setMockInitialValues({'local_imported_stories': saved});
      final actual = LocalLibrarySearchIndex(repository: repository);
      expect(
        (await actual.search(
          source,
          const UnifiedSearchQuery(text: 'Saved'),
          1,
        )).items.single.story.content,
        'BOOK_BODY',
      );
      expect(
        (await SharedPreferences.getInstance()).getStringList(
          'local_imported_stories',
        ),
        saved,
      );
    },
  );
}
