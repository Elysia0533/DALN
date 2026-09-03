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

      expect(await database.getVersion(), 1);
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

      final story = await repository.findByDriveFileId('drive-1');
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
    final original = await repository.findByDriveFileId('drive-1');

    await repository.upsertStories([
      _story(
        remoteId: 'story-1',
        driveFileId: 'drive-1',
        title: 'New title',
        authors: const ['Author B'],
        genres: const ['Genre B', 'Genre C'],
      ),
    ]);
    final updated = await repository.findByDriveFileId('drive-1');

    expect(updated, isNotNull);
    expect(updated!.databaseId, original!.databaseId);
    expect(updated.title, 'New title');
    expect(updated.authors, const ['Author B']);
    expect(updated.genres, const ['Genre B', 'Genre C']);
    expect(await repository.countStories(), 1);
  });

  test('unique Drive conflict rolls back every story in the batch', () async {
    await repository.upsertStories([
      _story(remoteId: 'existing', driveFileId: 'drive-1', title: 'Existing'),
    ]);

    await expectLater(
      repository.upsertStories([
        _story(
          remoteId: 'new-valid',
          driveFileId: 'drive-2',
          title: 'Should roll back',
        ),
        _story(
          remoteId: 'new-conflict',
          driveFileId: 'drive-1',
          title: 'Conflicting Drive identity',
        ),
      ]),
      throwsA(isA<DatabaseException>()),
    );

    expect(await repository.countStories(), 1);
    expect(
      await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'drive-root',
        remoteId: 'new-valid',
      ),
      isNull,
    );
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
      final restored = await repository.findByDriveFileId('drive-1');

      expect(restored?.title, 'Persistent story');
      expect(restored?.authors, const ['Persistent author']);
      expect(await (await databaseService.database).getVersion(), 1);
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
