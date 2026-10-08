import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:online_story_reader/models/drive_metadata.dart';
import 'package:online_story_reader/models/search_index_state.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/services/database/database_service.dart';
import 'package:online_story_reader/services/search/book_metadata_extractor.dart';
import 'package:online_story_reader/services/search/drive_metadata_indexer.dart';
import 'package:online_story_reader/services/search/drive_search_coordinator.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';
import 'package:online_story_reader/services/search/txt_metadata_extractor.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late DatabaseService database;
  late SearchIndexRepository repository;
  late DriveMetadataSnapshot snapshot;
  var run = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vbook-publish-');
    database = DatabaseService(
      factory: databaseFactoryFfi,
      pathResolver: () async => path.join(directory.path, 'index.db'),
    );
    repository = SearchIndexRepository(database);
    snapshot = _snapshot([]);
    run = 0;
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  DriveMetadataIndexer indexer({
    TxtMetadataLoader? txt,
    BookMetadataLoader? epub,
  }) => DriveMetadataIndexer(
    repository: repository,
    snapshotLoader: (_) async => snapshot,
    folderIdParser: (input) => input,
    runIdFactory: () => 'publish-${++run}',
    txtMetadataLoader: txt,
    epubMetadataLoader: epub,
  );

  test(
    'search sees a committed pair while later extraction is blocked',
    () async {
      snapshot = _snapshot([
        _record('txt', mime: 'text/plain'),
        _record('epub'),
        _record('slow'),
      ]);
      final started = Completer<void>();
      final slow = Completer<BookMetadata>();
      var extractions = 0;
      final worker = indexer(
        txt: (id) async {
          extractions++;
          return TxtMetadata(title: 'Extracted $id');
        },
        epub: (id) async {
          extractions++;
          if (id == 'slow') {
            started.complete();
            return slow.future;
          }
          return BookMetadata(title: 'Extracted $id');
        },
      );
      final coordinator = DriveSearchCoordinator(
        repository: repository,
        synchronizeFolder: worker.synchronizeFolder,
      );
      addTearDown(coordinator.dispose);
      var finished = false;
      final sync = coordinator
          .synchronize(['root'])
          .then((_) => finished = true);
      await started.future.timeout(const Duration(seconds: 5));
      try {
        expect(finished, isFalse);
        expect(coordinator.state.status, SearchIndexStatus.indexing);
        expect(coordinator.state.indexedCount, 2);
        expect(coordinator.state.totalCount, 3);
        expect(coordinator.state.completedSources, 0);
        expect(coordinator.state.dataRevision, 1);
        expect(
          (await coordinator.search(query: 'Extracted')).items,
          hasLength(2),
        );
        final jobs = await repository.loadIndexJobsForSource(
          sourceType: 'googleDrive',
          sourceId: 'root',
        );
        expect(jobs['txt']!.status, SearchIndexJobStatus.complete);
        expect(jobs['slow']!.status, SearchIndexJobStatus.running);
      } finally {
        slow.complete(const BookMetadata(title: 'Extracted slow'));
        await sync;
      }
      expect(coordinator.state.indexedCount, 3);
      expect(coordinator.state.status, SearchIndexStatus.partial);
      await database.close();
      await coordinator.synchronize(['root'], force: true);
      expect(
        extractions,
        3,
        reason: 'Committed partial successes survive reopening',
      );
      expect(
        (await coordinator.search(query: 'Extracted')).items,
        hasLength(3),
      );
    },
  );

  test('fast catalog commits stay bounded at 100 without extraction', () async {
    snapshot = _snapshot([
      for (var i = 0; i < 250; i++) _record('$i', complete: true),
    ]);
    final updates = <DriveIndexProgress>[];
    final worker = indexer(
      epub: (_) => throw StateError('Unexpected download'),
    );
    final result = await worker.synchronizeFolder(
      'root',
      onProgress: updates.add,
    );
    expect(result.writtenCount, 250);
    expect(updates.map((value) => value.indexedCount), [100, 200, 250]);
    expect(updates.every((value) => value.metadataChanged), isTrue);
    updates.clear();
    final unchanged = await worker.synchronizeFolder(
      'root',
      onProgress: updates.add,
    );
    expect(unchanged.writtenCount, 0);
    expect(unchanged.unchangedCount, 250);
    expect(updates.every((value) => !value.metadataChanged), isTrue);
  });

  test('a later invalid identity cannot publish or prune any batch', () async {
    snapshot = _snapshot([_record('original', complete: true)]);
    final worker = indexer();
    await worker.synchronizeFolder('root');
    snapshot = _snapshot([
      for (var i = 0; i < 110; i++) _record('$i', complete: true),
      _record('0', complete: true),
    ]);
    final updates = <DriveIndexProgress>[];
    final result = await worker.synchronizeFolder(
      'root',
      onProgress: updates.add,
    );
    expect(result.errorCode, 'invalid_snapshot');
    expect(result.writtenCount, 0);
    expect(result.deletedCount, 0);
    expect(updates, isEmpty);
    expect(await repository.countStories(), 1);
    expect(
      await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'original',
      ),
      isNotNull,
    );
  });

  test(
    'same-count metadata changes notify before a source is complete',
    () async {
      snapshot = _snapshot([_record('one'), _record('two'), _record('slow')]);
      await indexer().synchronizeFolder('root');
      final started = Completer<void>();
      final slow = Completer<BookMetadata>();
      final worker = indexer(
        epub: (id) async {
          if (id == 'slow') {
            started.complete();
            return slow.future;
          }
          return BookMetadata(title: 'Updated $id');
        },
      );
      final coordinator = DriveSearchCoordinator(
        repository: repository,
        synchronizeFolder: worker.synchronizeFolder,
      );
      addTearDown(coordinator.dispose);
      await coordinator.restoreState(['root']);
      final sync = coordinator.synchronize(['root'], force: true);
      await started.future.timeout(const Duration(seconds: 5));
      try {
        expect(coordinator.state.indexedCount, 3);
        expect(coordinator.state.completedSources, 0);
        expect(coordinator.state.dataRevision, 1);
        expect(
          (await coordinator.search(query: 'Updated')).items,
          hasLength(2),
        );
      } finally {
        slow.complete(const BookMetadata());
        await sync;
      }
    },
  );

  test(
    'later write failure preserves published metadata and successful jobs',
    () async {
      snapshot = _snapshot([_record('old', complete: true)]);
      await indexer().synchronizeFolder('root');
      repository = _FailingRepository(database);
      snapshot = _snapshot([_record('one'), _record('two'), _record('three')]);
      var attempts = 0;
      Future<BookMetadata> extract(String id) async {
        attempts++;
        return BookMetadata(title: 'Extracted $id');
      }

      final updates = <DriveIndexProgress>[];
      final failed = await indexer(
        epub: extract,
      ).synchronizeFolder('root', onProgress: updates.add);
      expect(failed.status, SearchIndexRunStatus.error);
      expect(failed.writtenCount, 2);
      expect(failed.indexedCount, 3);
      expect(failed.deletedCount, 0);
      expect(updates.single.indexedCount, 3);
      expect(
        await repository.findByIdentity(
          sourceType: 'googleDrive',
          sourceId: 'root',
          remoteId: 'old',
        ),
        isNotNull,
      );
      await database.close();
      repository = SearchIndexRepository(database);
      final resumed = await indexer(epub: extract).synchronizeFolder('root');
      expect(
        attempts,
        4,
        reason: 'Only the uncommitted third file is extracted again',
      );
      expect(resumed.indexedCount, 3);
      expect(resumed.deletedCount, 1);
    },
  );
}

DriveMetadataSnapshot _snapshot(List<DriveMetadataRecord> records) =>
    DriveMetadataSnapshot(
      sourceId: 'root',
      records: records,
      traversalComplete: true,
    );

DriveMetadataRecord _record(
  String id, {
  String mime = 'application/epub+zip',
  bool complete = false,
}) => DriveMetadataRecord(
  driveFileId: id,
  fileName: '$id.epub',
  title: 'Book $id',
  mimeType: mime,
  checksum: 'revision-$id',
  authors: complete ? ['Author'] : [],
  genres: complete ? ['Novel'] : [],
  metadataStatus: complete
      ? SearchMetadataStatus.complete
      : SearchMetadataStatus.missing,
  origin: complete
      ? DriveMetadataOrigin.catalog
      : DriveMetadataOrigin.driveFile,
);

class _FailingRepository extends SearchIndexRepository {
  _FailingRepository(super.databaseService);
  var writes = 0;

  @override
  Future<void> upsertStories(Iterable<SearchIndexStory> stories) {
    if (stories.isNotEmpty && ++writes == 2) {
      throw StateError('Injected failure after a committed batch');
    }
    return super.upsertStories(stories);
  }
}
