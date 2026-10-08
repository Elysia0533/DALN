import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:online_story_reader/models/search_index_state.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/services/database/database_service.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';
import 'package:online_story_reader/services/search/search_text_normalizer.dart';

void main() {
  sqfliteFfiInit();

  late Directory temporaryDirectory;
  late String databasePath;
  late DatabaseService databaseService;
  late SearchIndexRepository repository;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vbook-search-index-',
    );
    databasePath = path.join(temporaryDirectory.path, 'vbook_index.db');
    databaseService = _testDatabaseService(databasePath);
    repository = SearchIndexRepository(databaseService);
  });

  tearDown(() async {
    await databaseService.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'schema v1 creates normalized relations, jobs, and lookup indexes',
    () async {
      final database = await databaseService.database;

      expect(await database.getVersion(), 2);
      final tableRows = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final tables = tableRows.map((row) => row['name']).toSet();
      expect(
        tables,
        containsAll(<String>{
          'stories',
          'authors',
          'story_authors',
          'genres',
          'story_genres',
          'index_runs',
          'index_jobs',
        }),
      );

      final indexRows = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      );
      final indexes = indexRows.map((row) => row['name']).toSet();
      expect(
        indexes,
        containsAll(<String>{
          'stories_drive_file_id_idx',
          'stories_normalized_title_idx',
          'story_authors_story_id_idx',
          'story_authors_author_id_idx',
          'story_genres_story_id_idx',
          'story_genres_genre_id_idx',
        }),
      );

      final foreignKeys = await database.rawQuery('PRAGMA foreign_keys');
      expect((foreignKeys.single['foreign_keys'] as num).toInt(), 1);

      final state = await repository.readIndexState(
        sourceType: 'googleDrive',
        sourceId: 'drive-root',
      );
      expect(state.status, SearchIndexStatus.notStarted);
      expect(state.indexedCount, 0);
    },
  );

  test(
    'normalizer folds Vietnamese accents without changing stored text',
    () async {
      expect(SearchTextNormalizer.normalize('  Tiên \n HIỆP  '), 'tien hiep');
      expect(SearchTextNormalizer.normalize('Đường về'), 'duong ve');
      expect(
        SearchTextNormalizer.normalize('Tie\u0302n Hie\u0323p'),
        'tien hiep',
      );

      await repository.upsertStories([
        _story(
          remoteId: 'story-1',
          driveFileId: 'drive-1',
          title: 'Tiên   Hiệp',
        ),
      ]);

      final database = await databaseService.database;
      final row = (await database.query('stories')).single;
      expect(row['title'], 'Tiên   Hiệp');
      expect(row['normalized_title'], 'tien hiep');
    },
  );

  test(
    'upsert stores metadata and normalized author and genre relations',
    () async {
      final modifiedTime = DateTime.utc(2026, 8, 31, 14, 30);
      final indexedAt = DateTime.utc(2026, 9, 1, 8, 15);
      await repository.upsertStories([
        _story(
          remoteId: 'story-1',
          driveFileId: 'drive-1',
          title: 'Mắt Biếc',
          modifiedTime: modifiedTime,
          lastIndexedAt: indexedAt,
          fileSize: 4096,
          checksum: 'checksum-1',
          authors: const [' Nguyễn Nhật Ánh ', 'nguyen nhat anh'],
          genres: const ['Tình Cảm', 'tinh cam', 'Văn Học'],
        ),
      ]);

      final story = await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'drive-root',
        remoteId: 'story-1',
      );
      expect(story, isNotNull);
      expect(story!.title, 'Mắt Biếc');
      expect(story.modifiedTime, modifiedTime);
      expect(story.lastIndexedAt, indexedAt);
      expect(story.fileSize, 4096);
      expect(story.checksum, 'checksum-1');
      expect(story.authors, const ['Nguyễn Nhật Ánh']);
      expect(story.genres, const ['Tình Cảm', 'Văn Học']);
      expect(story.metadataStatus, SearchMetadataStatus.partial);

      final database = await databaseService.database;
      expect(await _tableCount(database, 'authors'), 1);
      expect(await _tableCount(database, 'genres'), 2);
      expect(await _tableCount(database, 'story_authors'), 1);
      expect(await _tableCount(database, 'story_genres'), 2);
    },
  );

  test('same remote ID remains distinct across source identities', () async {
    await repository.upsertStories([
      _story(
        sourceId: 'drive-root-a',
        remoteId: 'shared-id',
        driveFileId: 'drive-a',
        title: 'Drive A',
      ),
      _story(
        sourceType: 'local',
        sourceId: 'device-library',
        remoteId: 'shared-id',
        title: 'Local copy',
      ),
    ]);

    expect(await repository.countStories(), 2);
    expect(
      (await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'drive-root-a',
        remoteId: 'shared-id',
      ))?.title,
      'Drive A',
    );
    expect(
      (await repository.findByIdentity(
        sourceType: 'local',
        sourceId: 'device-library',
        remoteId: 'shared-id',
      ))?.title,
      'Local copy',
    );
  });

  test('upsert updates one identity and replaces its relations', () async {
    await repository.upsertStories([
      _story(
        remoteId: 'story-1',
        driveFileId: 'drive-1',
        title: 'Old title',
        authors: const ['Author A'],
        genres: const ['Genre A'],
      ),
    ]);
    final original = await repository.findByIdentity(
      sourceType: 'googleDrive',
      sourceId: 'drive-root',
      remoteId: 'story-1',
    );

    await repository.upsertStories([
      _story(
        remoteId: 'story-1',
        driveFileId: 'drive-1',
        title: 'New title',
        authors: const ['Author B'],
        genres: const ['Genre B', 'Genre C'],
      ),
    ]);
    final updated = await repository.findByIdentity(
      sourceType: 'googleDrive',
      sourceId: 'drive-root',
      remoteId: 'story-1',
    );

    expect(updated, isNotNull);
    expect(updated!.databaseId, original!.databaseId);
    expect(updated.title, 'New title');
    expect(updated.authors, const ['Author B']);
    expect(updated.genres, const ['Genre B', 'Genre C']);
    expect(await repository.countStories(), 1);
  });

  test('invalid metadata is rejected before any batch write', () async {
    await expectLater(
      repository.upsertStories([
        _story(remoteId: 'valid', title: 'Valid'),
        _story(remoteId: 'invalid', title: '   '),
      ]),
      throwsArgumentError,
    );

    expect(await repository.countStories(), 0);
  });

  test(
    'title search folds Vietnamese text and treats LIKE symbols literally',
    () async {
      await repository.upsertStories([
        _story(
          remoteId: 'literal-symbols',
          driveFileId: 'drive-symbols',
          title: 'Tiên Hiệp 100%_Ready!',
        ),
        _story(
          remoteId: 'plain-text',
          driveFileId: 'drive-plain',
          title: 'Tiên Hiệp 100 percent ready',
        ),
      ]);

      final normalized = await repository.searchByTitle('tien hiep');
      final literalSymbols = await repository.searchByTitle('%_');
      final injectionAttempt = await repository.searchByTitle(
        "missing' OR 1=1 --",
      );

      expect(normalized.items.map((story) => story.remoteId), {
        'literal-symbols',
        'plain-text',
      });
      expect(literalSymbols.items.map((story) => story.remoteId), [
        'literal-symbols',
      ]);
      expect(injectionAttempt.items, isEmpty);
    },
  );

  test('author search queries normalized relation rows in SQL', () async {
    await repository.upsertStories([
      _story(
        remoteId: 'mat-biec',
        title: 'Mắt Biếc',
        authors: const ['Nguyễn Nhật Ánh'],
      ),
      _story(
        remoteId: 'canh-dong',
        title: 'Cánh Đồng Bất Tận',
        authors: const ['Nguyễn Ngọc Tư'],
      ),
    ]);

    final result = await repository.searchByAuthor('nhat anh');

    expect(result.items.map((story) => story.remoteId), ['mat-biec']);
    expect(result.items.single.authors, const ['Nguyễn Nhật Ánh']);
  });

  test('genre search uses an exact normalized genre filter', () async {
    await repository.upsertStories([
      _story(
        remoteId: 'cultivation',
        title: 'Tu Tiên',
        genres: const ['Tiên Hiệp'],
      ),
      _story(
        remoteId: 'comedy',
        title: 'Tu Tiên Hài',
        genres: const ['Tiên Hiệp Hài'],
      ),
    ]);

    final result = await repository.searchByGenre('tien hiep');

    expect(result.items.map((story) => story.remoteId), ['cultivation']);
  });

  test('keyword search matches title, author, or genre in SQLite', () async {
    await repository.upsertStories([
      _story(remoteId: 'title', title: 'Dòng Sông Ký Ức'),
      _story(
        remoteId: 'author',
        title: 'Nỗi Buồn Chiến Tranh',
        authors: const ['Bảo Ninh'],
      ),
      _story(
        remoteId: 'genre',
        title: 'Biên Niên Sử',
        genres: const ['Lịch Sử'],
      ),
    ]);

    final byTitle = await repository.searchByKeyword(query: 'dong song');
    final byAuthor = await repository.searchByKeyword(query: 'bao ninh');
    final byGenre = await repository.searchByKeyword(query: 'lich su');

    expect(byTitle.items.map((story) => story.remoteId), ['title']);
    expect(byAuthor.items.map((story) => story.remoteId), ['author']);
    expect(byGenre.items.map((story) => story.remoteId), ['genre']);
  });

  test('keyword search treats selected genres as an OR filter', () async {
    await repository.upsertStories([
      _story(
        remoteId: 'fantasy',
        title: 'Fantasy story',
        genres: const ['Kỳ Ảo'],
      ),
      _story(
        remoteId: 'children',
        title: 'Children story',
        genres: const ['Thiếu Nhi'],
      ),
      _story(
        remoteId: 'history',
        title: 'History story',
        genres: const ['Lịch Sử'],
      ),
    ]);

    final result = await repository.searchByKeyword(
      genres: const ['ky ao', 'thiếu nhi'],
    );

    expect(result.items.map((story) => story.remoteId).toSet(), {
      'fantasy',
      'children',
    });
  });

  test('author and genre facets are distinct and source scoped', () async {
    await repository.upsertStories([
      _story(
        remoteId: 'drive-a',
        title: 'Drive A',
        authors: const ['Nguyễn Nhật Ánh'],
        genres: const ['Thiếu Nhi'],
      ),
      _story(
        remoteId: 'drive-b',
        title: 'Drive B',
        authors: const ['Nguyễn Nhật Ánh', 'Tô Hoài'],
        genres: const ['Thiếu Nhi', 'Phiêu Lưu'],
      ),
      _story(
        sourceType: 'extension',
        sourceId: 'extension-a',
        remoteId: 'extension-story',
        title: 'Extension story',
        authors: const ['Extension Author'],
        genres: const ['Extension Genre'],
      ),
    ]);

    final authors = await repository.listAuthors(sourceType: 'googleDrive');
    final genres = await repository.listGenres(sourceType: 'googleDrive');

    expect(authors, ['Nguyễn Nhật Ánh', 'Tô Hoài']);
    expect(genres, ['Phiêu Lưu', 'Thiếu Nhi']);
  });

  test(
    'combined search requires every selected label and respects source scope',
    () async {
      await repository.upsertStories([
        _story(
          sourceId: 'drive-root',
          remoteId: 'target',
          driveFileId: 'drive-target',
          title: 'Hành Trình Phương Nam',
          authors: const ['Nguyễn Văn A', 'Trần Văn B'],
          genres: const ['Kỳ Ảo', 'Phiêu Lưu'],
        ),
        _story(
          sourceId: 'drive-root',
          remoteId: 'missing-genre',
          driveFileId: 'drive-missing-genre',
          title: 'Hành Trình Phương Bắc',
          authors: const ['Nguyễn Văn A', 'Trần Văn B'],
          genres: const ['Phiêu Lưu'],
        ),
        _story(
          sourceId: 'another-root',
          remoteId: 'other-source',
          driveFileId: 'drive-other-source',
          title: 'Hành Trình Phương Nam',
          authors: const ['Nguyễn Văn A', 'Trần Văn B'],
          genres: const ['Kỳ Ảo', 'Phiêu Lưu'],
        ),
      ]);

      final result = await repository.searchCombined(
        query: 'hanh trinh',
        authors: const ['nguyen van a', 'Trần Văn B'],
        genres: const ['ky ao', 'Phiêu Lưu'],
        sourceType: 'googleDrive',
        sourceId: 'drive-root',
      );

      expect(result.items.map((story) => story.remoteId), ['target']);
      await expectLater(
        repository.searchCombined(sourceId: 'drive-root'),
        throwsArgumentError,
      );
    },
  );

  test('search pagination is stable and exposes the next offset', () async {
    await repository.upsertStories([
      for (var index = 1; index <= 23; index++)
        _story(
          remoteId: 'series-$index',
          driveFileId: 'series-drive-$index',
          title: 'Series ${index.toString().padLeft(2, '0')}',
        ),
    ]);

    final first = await repository.searchByTitle('series', limit: 10);
    final second = await repository.searchByTitle(
      'series',
      limit: 10,
      offset: first.nextOffset!,
    );
    final third = await repository.searchByTitle(
      'series',
      limit: 10,
      offset: second.nextOffset!,
    );

    expect(first.items.length, 10);
    expect(first.hasMore, isTrue);
    expect(first.nextOffset, 10);
    expect(second.items.length, 10);
    expect(second.hasMore, isTrue);
    expect(second.nextOffset, 20);
    expect(third.items.length, 3);
    expect(third.hasMore, isFalse);
    expect(third.nextOffset, isNull);
    expect(
      [
        ...first.items,
        ...second.items,
        ...third.items,
      ].map((story) => story.remoteId).toSet().length,
      23,
    );
  });

  test('search finds item 400 after a 500-record index', () async {
    final stories = [
      for (var index = 1; index <= 500; index++)
        _story(
          remoteId: 'story-$index',
          driveFileId: 'large-drive-$index',
          title: index == 400
              ? 'Kho Báu Bí Mật'
              : 'Story ${index.toString().padLeft(3, '0')}',
        ),
    ];
    for (
      var start = 0;
      start < stories.length;
      start += SearchIndexRepository.maxUpsertBatchSize
    ) {
      await repository.upsertStories(
        stories.skip(start).take(SearchIndexRepository.maxUpsertBatchSize),
      );
    }

    final result = await repository.searchByTitle(
      'kho bau bi mat',
      sourceType: 'googleDrive',
      sourceId: 'drive-root',
      limit: 15,
    );

    expect(await repository.countStories(), 500);
    expect(result.items.map((story) => story.remoteId), ['story-400']);
  });

  test(
    'indexed results remain searchable while index state is partial',
    () async {
      await repository.startIndexRun(
        SearchIndexRunRecord(
          runId: 'running-search',
          sourceType: 'googleDrive',
          sourceId: 'drive-root',
          status: SearchIndexRunStatus.indexing,
          indexedCount: 1,
          totalCount: 500,
          startedAt: DateTime.utc(2026, 9, 3),
        ),
      );
      await repository.upsertStories([
        _story(remoteId: 'indexed', title: 'Already Indexed'),
      ]);

      final result = await repository.searchByTitle('already indexed');
      final state = await repository.readIndexState(
        sourceType: 'googleDrive',
        sourceId: 'drive-root',
      );

      expect(result.items.map((story) => story.remoteId), ['indexed']);
      expect(state.status, SearchIndexStatus.indexing);
      expect(state.indexedCount, 1);
      expect(state.totalCount, 500);
    },
  );

  test(
    'schema and metadata survive closing and reopening the database',
    () async {
      await repository.upsertStories([
        _story(
          remoteId: 'story-1',
          driveFileId: 'drive-1',
          title: 'Persistent story',
          authors: const ['Persistent author'],
        ),
      ]);
      await databaseService.close();

      databaseService = _testDatabaseService(databasePath);
      repository = SearchIndexRepository(databaseService);
      final restored = await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'drive-root',
        remoteId: 'story-1',
      );

      expect(restored?.title, 'Persistent story');
      expect(restored?.authors, const ['Persistent author']);
      expect(await (await databaseService.database).getVersion(), 2);
    },
  );

  test(
    'cross-source search deduplicates same driveFileId across roots',
    () async {
      // Insert the same Drive file in two different roots with different
      // metadata quality.
      await repository.upsertStories([
        _story(
          sourceId: 'root-a',
          remoteId: 'shared-file',
          driveFileId: 'drive-shared',
          title: 'Book from Root A',
          authors: const ['Author A'],
          genres: const ['Genre A'],
        ),
      ]);
      // Root B has the same driveFileId but with complete metadata.
      await repository.upsertStories([
        SearchIndexStory(
          sourceType: 'googleDrive',
          sourceId: 'root-b',
          remoteId: 'shared-file',
          driveFileId: 'drive-shared',
          title: 'Book from Root B (better)',
          mimeType: 'application/epub+zip',
          description: 'Full description',
          metadataStatus: SearchMetadataStatus.complete,
          lastIndexedAt: DateTime.utc(2026, 9, 5),
          authors: const ['Author B'],
          genres: const ['Genre B'],
        ),
      ]);

      // Both records exist in the database.
      expect(await repository.countStories(), 2);

      // Cross-source search (no sourceType/sourceId) should deduplicate.
      final crossResults = await repository.searchByKeyword(query: 'book');
      expect(crossResults.items, hasLength(1));
      expect(crossResults.items.first.title, 'Book from Root B (better)');
      expect(
        crossResults.items.first.metadataStatus,
        SearchMetadataStatus.complete,
      );

      // Root-scoped search should NOT deduplicate — returns exactly one hit.
      final rootAResults = await repository.searchByKeyword(
        query: 'book',
        sourceType: 'googleDrive',
        sourceId: 'root-a',
      );
      expect(rootAResults.items, hasLength(1));
      expect(rootAResults.items.first.title, 'Book from Root A');

      final rootBResults = await repository.searchByKeyword(
        query: 'book',
        sourceType: 'googleDrive',
        sourceId: 'root-b',
      );
      expect(rootBResults.items, hasLength(1));
      expect(rootBResults.items.first.title, 'Book from Root B (better)');
    },
  );

  test(
    'dedup keeps record with better metadata when driveFileId overlaps',
    () async {
      // Root A has partial metadata.
      await repository.upsertStories([
        _story(
          sourceId: 'root-a',
          remoteId: 'overlap-file',
          driveFileId: 'drive-overlap',
          title: 'Overlap',
          lastIndexedAt: DateTime.utc(2026, 9, 10),
        ),
      ]);
      // Root B has partial metadata but older timestamp.
      await repository.upsertStories([
        _story(
          sourceId: 'root-b',
          remoteId: 'overlap-file',
          driveFileId: 'drive-overlap',
          title: 'Overlap',
          lastIndexedAt: DateTime.utc(2026, 9, 1),
        ),
      ]);

      // Both have same metadata_status (partial); root-a has newer timestamp.
      final results = await repository.searchByKeyword(query: 'overlap');
      expect(results.items, hasLength(1));
      expect(results.items.first.sourceId, 'root-a');
    },
  );

  test(
    'records without driveFileId are never deduplicated',
    () async {
      await repository.upsertStories([
        _story(
          sourceType: 'local',
          sourceId: 'device',
          remoteId: 'local-1',
          driveFileId: null,
          title: 'Local Book A',
        ),
        _story(
          sourceType: 'local',
          sourceId: 'device',
          remoteId: 'local-2',
          driveFileId: null,
          title: 'Local Book B',
        ),
      ]);

      final results = await repository.searchByKeyword(query: 'local book');
      expect(results.items, hasLength(2));
    },
  );

  test(
    'deleting one root does not affect another root with same driveFileId',
    () async {
      await repository.upsertStories([
        _story(
          sourceId: 'root-x',
          remoteId: 'shared-x',
          driveFileId: 'drive-xy',
          title: 'Shared XY',
        ),
      ]);
      await repository.upsertStories([
        _story(
          sourceId: 'root-y',
          remoteId: 'shared-y',
          driveFileId: 'drive-xy',
          title: 'Shared XY',
        ),
      ]);

      // Simulate root-x reconciliation removing its record.
      await repository.startIndexRun(SearchIndexRunRecord(
        runId: 'cleanup-x',
        sourceType: 'googleDrive',
        sourceId: 'root-x',
        status: SearchIndexRunStatus.indexing,
        indexedCount: 0,
        startedAt: DateTime.utc(2026, 9, 11),
      ));
      // No stories seen in this run → all root-x stories get deleted.
      final deleted = await repository.deleteStoriesNotSeenInRun(
        sourceType: 'googleDrive',
        sourceId: 'root-x',
        runId: 'cleanup-x',
      );
      expect(deleted, 1);

      // Root-y record survives.
      expect(await repository.countStories(), 1);
      final surviving = await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root-y',
        remoteId: 'shared-y',
      );
      expect(surviving, isNotNull);
      expect(surviving!.title, 'Shared XY');
    },
  );
}

DatabaseService _testDatabaseService(String databasePath) {
  return DatabaseService(
    factory: databaseFactoryFfi,
    pathResolver: () async => databasePath,
  );
}

SearchIndexStory _story({
  String sourceType = 'googleDrive',
  String sourceId = 'drive-root',
  required String remoteId,
  String? driveFileId,
  required String title,
  DateTime? modifiedTime,
  DateTime? lastIndexedAt,
  int? fileSize,
  String? checksum,
  List<String> authors = const [],
  List<String> genres = const [],
}) {
  return SearchIndexStory(
    sourceType: sourceType,
    sourceId: sourceId,
    remoteId: remoteId,
    driveFileId: driveFileId,
    title: title,
    mimeType: 'application/epub+zip',
    modifiedTime: modifiedTime,
    fileSize: fileSize,
    checksum: checksum,
    description: 'Indexed metadata',
    coverFileId: driveFileId == null ? null : 'cover-$driveFileId',
    coverUrl: driveFileId == null ? null : 'https://example.invalid/cover.jpg',
    coverLocalPath: driveFileId == null ? null : 'covers/$driveFileId.jpg',
    metadataStatus: SearchMetadataStatus.partial,
    lastIndexedAt: lastIndexedAt ?? DateTime.utc(2026, 9, 1),
    authors: authors,
    genres: genres,
  );
}

Future<int> _tableCount(Database database, String table) async {
  final rows = await database.rawQuery(
    'SELECT COUNT(*) AS row_count FROM $table',
  );
  return (rows.single['row_count'] as num).toInt();
}
