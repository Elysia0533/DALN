import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:online_story_reader/models/drive_metadata.dart';
import 'package:online_story_reader/models/search_index_state.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/services/database/database_service.dart';
import 'package:online_story_reader/services/search/drive_metadata_indexer.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';

void main() {
  sqfliteFfiInit();

  late Directory temporaryDirectory;
  late DatabaseService databaseService;
  late SearchIndexRepository repository;
  late DriveMetadataSnapshot snapshot;
  late DateTime now;
  late int runNumber;
  late int loaderCalls;
  Object? loaderError;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vbook-drive-indexer-',
    );
    databaseService = DatabaseService(
      factory: databaseFactoryFfi,
      pathResolver: () async => path.join(temporaryDirectory.path, 'index.db'),
    );
    repository = SearchIndexRepository(databaseService);
    snapshot = _snapshot(const []);
    now = DateTime.utc(2026, 9, 1);
    runNumber = 0;
    loaderCalls = 0;
    loaderError = null;
  });

  tearDown(() async {
    await databaseService.close();
    await temporaryDirectory.delete(recursive: true);
  });

  DriveMetadataIndexer createIndexer() {
    return DriveMetadataIndexer(
      repository: repository,
      snapshotLoader: (sourceId) async {
        loaderCalls++;
        final error = loaderError;
        if (error != null) throw error;
        return snapshot;
      },
      folderIdParser: (input) => input == 'root' ? input : null,
      clock: () => now,
      runIdFactory: () => 'run-${++runNumber}',
    );
  }

  test(
    'indexes 500 Drive records independently from Explore pagination',
    () async {
      snapshot = _snapshot([
        for (var index = 1; index <= 500; index++)
          _record(
            id: 'story-$index',
            title: 'Story $index',
            checksum: 'checksum-$index',
          ),
      ]);

      final result = await createIndexer().synchronizeFolder('root');

      expect(result.status, SearchIndexRunStatus.ready);
      expect(result.totalCount, 500);
      expect(result.indexedCount, 500);
      expect(result.writtenCount, 500);
      expect(await repository.countStories(), 500);
      expect(
        (await repository.findByIdentity(
          sourceType: DriveMetadataIndexer.sourceType,
          sourceId: 'root',
          remoteId: 'story-400',
        ))?.title,
        'Story 400',
      );
    },
  );

  test('unchanged files are marked seen without rewriting metadata', () async {
    snapshot = _snapshot([_record(id: 'story-1', title: 'Story')]);
    final indexer = createIndexer();
    await indexer.synchronizeFolder('root');
    final firstStory = await repository.findByDriveFileId('story-1');
    final firstJobs = await repository.loadIndexJobsForSource(
      sourceType: DriveMetadataIndexer.sourceType,
      sourceId: 'root',
    );

    now = DateTime.utc(2026, 9, 2);
    final second = await indexer.synchronizeFolder('root');
    final secondStory = await repository.findByDriveFileId('story-1');
    final secondJobs = await repository.loadIndexJobsForSource(
      sourceType: DriveMetadataIndexer.sourceType,
      sourceId: 'root',
    );

    expect(second.writtenCount, 0);
    expect(second.unchangedCount, 1);
    expect(secondStory?.lastIndexedAt, firstStory?.lastIndexedAt);
    expect(secondStory?.lastSeenRunId, 'run-2');
    expect(secondJobs['story-1']?.updatedAt, firstJobs['story-1']?.updatedAt);
  });

  test(
    'changed revision is reindexed and updates its extraction job',
    () async {
      snapshot = _snapshot([_record(id: 'story-1', title: 'Old title')]);
      final indexer = createIndexer();
      await indexer.synchronizeFolder('root');

      now = DateTime.utc(2026, 9, 2);
      snapshot = _snapshot([
        _record(
          id: 'story-1',
          title: 'New title',
          checksum: 'changed-checksum',
        ),
      ]);
      final result = await indexer.synchronizeFolder('root');
      final story = await repository.findByDriveFileId('story-1');

      expect(result.writtenCount, 1);
      expect(result.unchangedCount, 0);
      expect(story?.title, 'New title');
      expect(story?.checksum, 'changed-checksum');
      expect(story?.lastIndexedAt, now);
    },
  );

  test('complete traversal deletes missing files and their jobs', () async {
    snapshot = _snapshot([
      _record(id: 'story-1', title: 'One'),
      _record(id: 'story-2', title: 'Two'),
    ]);
    final indexer = createIndexer();
    await indexer.synchronizeFolder('root');

    snapshot = _snapshot([_record(id: 'story-2', title: 'Two')]);
    final result = await indexer.synchronizeFolder('root');
    final jobs = await repository.loadIndexJobsForSource(
      sourceType: DriveMetadataIndexer.sourceType,
      sourceId: 'root',
    );

    expect(result.deletedCount, 1);
    expect(await repository.findByDriveFileId('story-1'), isNull);
    expect(await repository.countStories(), 1);
    expect(jobs.keys, const ['story-2']);
  });

  test(
    'incomplete traversal and loader failures preserve prior records',
    () async {
      snapshot = _snapshot([
        _record(id: 'story-1', title: 'One'),
        _record(id: 'story-2', title: 'Two'),
      ]);
      final indexer = createIndexer();
      await indexer.synchronizeFolder('root');

      snapshot = _snapshot([
        _record(id: 'story-2', title: 'Two'),
      ], traversalComplete: false);
      final partial = await indexer.synchronizeFolder('root');
      expect(partial.status, SearchIndexRunStatus.partial);
      expect(partial.errorCode, 'traversal_incomplete');
      expect(partial.deletedCount, 0);
      expect(await repository.countStories(), 2);

      loaderError = StateError('request failed');
      final failed = await indexer.synchronizeFolder('root');
      expect(failed.status, SearchIndexRunStatus.error);
      expect(failed.errorCode, 'sync_failed');
      expect(failed.totalCount, isNull);
      expect(await repository.countStories(), 2);
      expect(
        (await repository.latestIndexRun(
          sourceType: DriveMetadataIndexer.sourceType,
          sourceId: 'root',
        ))?.status,
        SearchIndexRunStatus.error,
      );
    },
  );

  test(
    'fallback scan does not downgrade unchanged complete metadata',
    () async {
      snapshot = _snapshot([_record(id: 'story-1', title: 'Catalog title')]);
      final indexer = createIndexer();
      await indexer.synchronizeFolder('root');

      now = DateTime.utc(2026, 9, 2);
      snapshot = _snapshot([
        _record(
          id: 'story-1',
          title: 'Filename fallback',
          status: SearchMetadataStatus.missing,
          origin: DriveMetadataOrigin.driveFile,
          authors: const [],
          genres: const [],
        ),
      ]);
      final result = await indexer.synchronizeFolder('root');
      final story = await repository.findByDriveFileId('story-1');

      expect(result.status, SearchIndexRunStatus.ready);
      expect(result.writtenCount, 0);
      expect(story?.title, 'Catalog title');
      expect(story?.authors, const ['Author']);
      expect(story?.genres, const ['Genre']);
      expect(story?.metadataStatus, SearchMetadataStatus.complete);
    },
  );

  test(
    'concurrent sync requests for one source share a single flight',
    () async {
      final loader = Completer<DriveMetadataSnapshot>();
      final indexer = DriveMetadataIndexer(
        repository: repository,
        snapshotLoader: (_) {
          loaderCalls++;
          return loader.future;
        },
        folderIdParser: (input) => input,
        clock: () => now,
        runIdFactory: () => 'run-${++runNumber}',
      );

      final first = indexer.synchronizeFolder('root');
      final second = indexer.synchronizeFolder('root');
      await Future<void>.delayed(Duration.zero);
      final runningState = await repository.readIndexState(
        sourceType: DriveMetadataIndexer.sourceType,
        sourceId: 'root',
      );

      expect(runningState.status, SearchIndexStatus.indexing);
      expect(runningState.indexedCount, 0);
      loader.complete(_snapshot([_record(id: 'story-1', title: 'Story')]));
      final results = await Future.wait([first, second]);

      expect(loaderCalls, 1);
      expect(runNumber, 1);
      expect(results.map((result) => result.runId).toSet(), {'run-1'});
      expect(
        (await repository.readIndexState(
          sourceType: DriveMetadataIndexer.sourceType,
          sourceId: 'root',
        )).status,
        SearchIndexStatus.ready,
      );
    },
  );
}

DriveMetadataSnapshot _snapshot(
  List<DriveMetadataRecord> records, {
  bool traversalComplete = true,
}) {
  return DriveMetadataSnapshot(
    sourceId: 'root',
    records: records,
    traversalComplete: traversalComplete,
  );
}

DriveMetadataRecord _record({
  required String id,
  required String title,
  String checksum = 'checksum',
  SearchMetadataStatus status = SearchMetadataStatus.complete,
  DriveMetadataOrigin origin = DriveMetadataOrigin.catalog,
  List<String> authors = const ['Author'],
  List<String> genres = const ['Genre'],
}) {
  return DriveMetadataRecord(
    driveFileId: id,
    fileName: '$title.epub',
    title: title,
    mimeType: 'application/epub+zip',
    modifiedTime: DateTime.utc(2026, 8, 31),
    fileSize: 4096,
    checksum: checksum,
    description: 'Description',
    coverFileId: 'cover-$id',
    coverUrl: 'https://example.invalid/$id.jpg',
    metadataStatus: status,
    origin: origin,
    authors: authors,
    genres: genres,
  );
}
