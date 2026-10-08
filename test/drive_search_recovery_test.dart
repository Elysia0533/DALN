import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:online_story_reader/models/drive_metadata.dart';
import 'package:online_story_reader/models/search_index_state.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/services/database/database_service.dart';
import 'package:online_story_reader/services/search/drive_metadata_indexer.dart';
import 'package:online_story_reader/services/search/drive_search_coordinator.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late DatabaseService database;
  late SearchIndexRepository repository;
  late DriveMetadataSnapshot snapshot;
  late DateTime now;
  var run = 0;
  Object? failure;

  void openDatabase() {
    database = DatabaseService(
      factory: databaseFactoryFfi,
      pathResolver: () async => path.join(directory.path, 'index.db'),
    );
    repository = SearchIndexRepository(database);
  }

  DriveMetadataIndexer indexer() => DriveMetadataIndexer(
    repository: repository,
    snapshotLoader: (_) async {
      if (failure != null) throw failure!;
      return snapshot;
    },
    folderIdParser: (value) => value,
    clock: () => now,
    runIdFactory: () => 'recovery-${++run}',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vbook-search-recovery-');
    openDatabase();
    now = DateTime.utc(2026, 9, 7);
    run = 0;
    failure = null;
    snapshot = _snapshot([_record('one'), _record('two')]);
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'failed sync retains the searchable count across database reopening',
    () async {
      await indexer().synchronizeFolder('root');
      now = now.add(const Duration(minutes: 31));
      failure = const SocketException('offline');
      final result = await indexer().synchronizeFolder('root');
      expect(result.status, SearchIndexRunStatus.error);
      expect(result.indexedCount, 2);
      await database.close();
      openDatabase();
      final coordinator = DriveSearchCoordinator(
        repository: repository,
        synchronizeFolder: indexer().synchronizeFolder,
      );
      addTearDown(coordinator.dispose);
      await coordinator.restoreState(['root']);
      expect(coordinator.state.status, SearchIndexStatus.error);
      expect(coordinator.state.indexedCount, 2);
      expect((await coordinator.search(query: 'Book')).items, hasLength(2));
    },
  );

  test(
    'an incomplete traversal keeps old rows and does not advertise a known total',
    () async {
      final worker = indexer();
      final coordinator = DriveSearchCoordinator(
        repository: repository,
        synchronizeFolder: worker.synchronizeFolder,
      );
      addTearDown(coordinator.dispose);
      await coordinator.synchronize(['root']);
      expect(coordinator.state.indexedCount, 2);
      snapshot = _snapshot([_record('one')], complete: false);
      now = now.add(const Duration(minutes: 31));
      await coordinator.synchronize(['root'], force: true);
      expect(coordinator.state.status, SearchIndexStatus.partial);
      expect(coordinator.state.indexedCount, 2);
      expect(coordinator.state.totalCount, isNull);
      await database.close();
      openDatabase();
      final state = await repository.readIndexState(
        sourceType: 'googleDrive',
        sourceId: 'root',
      );
      expect(state.indexedCount, 2);
      expect(state.totalCount, isNull);
      expect((await repository.searchByTitle('Book')).items, hasLength(2));
    },
  );

  test(
    'interrupted run restores actual source rows rather than its initial zero counter',
    () async {
      await indexer().synchronizeFolder('root');
      await repository.upsertStories([
        SearchIndexStory(
          sourceType: 'local',
          sourceId: 'library',
          remoteId: 'other',
          title: 'Unrelated book',
          lastIndexedAt: now,
        ),
      ]);
      await repository.startIndexRun(
        SearchIndexRunRecord(
          runId: 'interrupted',
          sourceType: 'googleDrive',
          sourceId: 'root',
          status: SearchIndexRunStatus.indexing,
          indexedCount: 0,
          startedAt: now.add(const Duration(minutes: 1)),
        ),
      );
      await database.close();
      openDatabase();
      final state = await repository.readIndexState(
        sourceType: 'googleDrive',
        sourceId: 'root',
      );
      expect(state.status, SearchIndexStatus.indexing);
      expect(state.indexedCount, 2);
      expect(state.totalCount, isNull);
      final recovered = await indexer().synchronizeFolder('root');
      expect(recovered.writtenCount, 0);
      expect(recovered.unchangedCount, 2);
      expect(recovered.indexedCount, 2);
    },
  );

  test(
    'unchanged revision after reopening does not rewrite story or job metadata',
    () async {
      await indexer().synchronizeFolder('root');
      final original = await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'one',
      );
      final jobs = await repository.loadIndexJobsForSource(
        sourceType: 'googleDrive',
        sourceId: 'root',
      );
      await database.close();
      openDatabase();
      now = now.add(const Duration(days: 1));
      final result = await indexer().synchronizeFolder('root');
      expect(result.writtenCount, 0);
      expect(result.unchangedCount, 2);
      expect(
        (await repository.findByIdentity(
          sourceType: 'googleDrive',
          sourceId: 'root',
          remoteId: 'one',
        ))!.lastIndexedAt,
        original!.lastIndexedAt,
      );
      expect(
        (await repository.loadIndexJobsForSource(
          sourceType: 'googleDrive',
          sourceId: 'root',
        ))['one']!.updatedAt,
        jobs['one']!.updatedAt,
      );
    },
  );

  for (final invalid in ['duplicate', 'empty-title', 'wrong-root']) {
    test(
      'invalid snapshot $invalid preserves previous search results and state count',
      () async {
        await indexer().synchronizeFolder('root');
        snapshot = switch (invalid) {
          'duplicate' => _snapshot([_record('one'), _record('one')]),
          'empty-title' => _snapshot([_record('one', title: '')]),
          _ => DriveMetadataSnapshot(
            sourceId: 'different',
            records: [],
            traversalComplete: true,
          ),
        };
        final result = await indexer().synchronizeFolder('root');
        expect(result.status, SearchIndexRunStatus.error);
        expect(result.indexedCount, 2);
        expect(result.deletedCount, 0);
        expect((await repository.searchByTitle('Book')).items, hasLength(2));
      },
    );
  }

  test(
    'a confirmed empty source deletes its old rows but not another library',
    () async {
      await indexer().synchronizeFolder('root');
      await repository.upsertStories([
        SearchIndexStory(
          sourceType: 'local',
          sourceId: 'library',
          remoteId: 'other',
          title: 'Local book',
          lastIndexedAt: now,
        ),
      ]);
      snapshot = _snapshot([]);
      final result = await indexer().synchronizeFolder('root');
      expect(result.status, SearchIndexRunStatus.ready);
      expect(result.indexedCount, 0);
      expect(result.totalCount, 0);
      expect(result.deletedCount, 2);
      expect(await repository.countStories(), 1);
    },
  );

  test(
    'a later failed batch reports all retained rows without pruning old records',
    () async {
      await indexer().synchronizeFolder('root');
      DriveMetadataIndexResult? syncResult;
      final coordinator = DriveSearchCoordinator(
        repository: repository,
        synchronizeFolder:
            (sourceId, {onProgress, retryFailedExtractions = false}) async {
              final result = await indexer().synchronizeFolder(
                sourceId,
                onProgress: onProgress,
                retryFailedExtractions: retryFailedExtractions,
              );
              syncResult = result;
              return result;
            },
      );
      addTearDown(coordinator.dispose);
      await coordinator.restoreState(['root']);
      snapshot = _snapshot([
        for (var index = 0; index < 100; index++) _record('new-$index'),
        DriveMetadataRecord(
          driveFileId: 'invalid',
          fileName: 'invalid.epub',
          title: 'Invalid size',
          mimeType: 'application/epub+zip',
          fileSize: -1,
          metadataStatus: SearchMetadataStatus.partial,
          origin: DriveMetadataOrigin.driveFile,
        ),
      ]);
      await coordinator.synchronize(['root'], force: true);
      final result = syncResult!;
      expect(result.status, SearchIndexRunStatus.error);
      expect(result.writtenCount, 100);
      expect(result.indexedCount, 102);
      expect(result.totalCount, isNull);
      expect(coordinator.state.indexedCount, 102);
      expect(coordinator.state.totalCount, isNull);
      expect(result.deletedCount, 0);
      expect(
        await repository.findByIdentity(
          sourceType: 'googleDrive',
          sourceId: 'root',
          remoteId: 'one',
        ),
        isNotNull,
      );
      expect(
        await repository.findByIdentity(
          sourceType: 'googleDrive',
          sourceId: 'root',
          remoteId: 'two',
        ),
        isNotNull,
      );
      expect(
        await repository.findByIdentity(
          sourceType: 'googleDrive',
          sourceId: 'root',
          remoteId: 'invalid',
        ),
        isNull,
      );
      await database.close();
      openDatabase();
      final state = await repository.readIndexState(
        sourceType: 'googleDrive',
        sourceId: 'root',
      );
      expect(state.indexedCount, 102);
      expect(state.totalCount, isNull);
    },
  );

  test(
    'unknown revision evidence cannot keep metadata from a previous version',
    () async {
      await indexer().synchronizeFolder('root');
      snapshot = _snapshot([
        DriveMetadataRecord(
          driveFileId: 'one',
          fileName: 'new.epub',
          title: 'New fallback',
          mimeType: 'application/epub+zip',
          metadataStatus: SearchMetadataStatus.missing,
          origin: DriveMetadataOrigin.driveFile,
        ),
      ]);
      final result = await indexer().synchronizeFolder('root');
      final story = await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'one',
      );
      expect(result.writtenCount, 1);
      expect(story!.title, 'New fallback');
      expect(story.authors, isEmpty);
      expect(story.genres, isEmpty);
      expect(story.metadataStatus, SearchMetadataStatus.missing);
    },
  );
}

DriveMetadataSnapshot _snapshot(
  List<DriveMetadataRecord> records, {
  bool complete = true,
}) => DriveMetadataSnapshot(
  sourceId: 'root',
  records: records,
  traversalComplete: complete,
);

DriveMetadataRecord _record(String id, {String? title}) => DriveMetadataRecord(
  driveFileId: id,
  fileName: '$id.epub',
  title: title ?? 'Book $id',
  mimeType: 'application/epub+zip',
  modifiedTime: DateTime.utc(2026),
  checksum: 'revision-$id',
  fileSize: 100,
  authors: ['Author'],
  genres: ['Novel'],
  metadataStatus: SearchMetadataStatus.complete,
  origin: DriveMetadataOrigin.catalog,
);
