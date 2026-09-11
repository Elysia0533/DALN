import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:online_story_reader/models/search_index_state.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/services/database/database_service.dart';
import 'package:online_story_reader/services/search/drive_metadata_indexer.dart';
import 'package:online_story_reader/services/search/drive_search_coordinator.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';

void main() {
  sqfliteFfiInit();

  late Directory temporaryDirectory;
  late DatabaseService databaseService;
  late SearchIndexRepository repository;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vbook-drive-search-coordinator-',
    );
    databaseService = DatabaseService(
      factory: databaseFactoryFfi,
      pathResolver: () async =>
          path.join(temporaryDirectory.path, 'vbook_index.db'),
    );
    repository = SearchIndexRepository(databaseService);
  });

  tearDown(() async {
    await databaseService.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('syncs unique Drive roots and skips a fresh ready index', () async {
    final calls = <String>[];
    final now = DateTime.utc(2026, 9, 4, 8);
    final coordinator = DriveSearchCoordinator(
      repository: repository,
      clock: () => now,
      synchronizeFolder:
          (sourceId, {onProgress, retryFailedExtractions = false}) async {
            calls.add(sourceId);
            return _result(
              sourceId: sourceId,
              status: SearchIndexRunStatus.ready,
              indexedCount: 12,
            );
          },
    );
    const folderUrl =
        'https://drive.google.com/drive/folders/drive-root?usp=sharing';

    await coordinator.restoreState(const [folderUrl, 'drive-root']);
    await coordinator.synchronize(const [folderUrl, 'drive-root']);

    expect(calls, ['drive-root']);
    expect(coordinator.state.status, SearchIndexStatus.ready);
    expect(coordinator.state.indexedCount, 12);
    expect(coordinator.state.completedSources, 1);
    expect(coordinator.state.totalSources, 1);

    await coordinator.synchronize(const ['drive-root']);
    expect(calls, ['drive-root']);

    await coordinator.synchronize(const ['drive-root'], force: true);
    expect(calls, ['drive-root', 'drive-root']);
  });

  test(
    'restores a persisted ready index without an immediate rescan',
    () async {
      final now = DateTime.utc(2026, 9, 4, 8);
      final completedAt = now.subtract(const Duration(minutes: 5));
      await repository.startIndexRun(
        SearchIndexRunRecord(
          runId: 'persisted-ready',
          sourceType: 'googleDrive',
          sourceId: 'drive-root',
          status: SearchIndexRunStatus.indexing,
          indexedCount: 0,
          startedAt: completedAt.subtract(const Duration(minutes: 1)),
        ),
      );
      await repository.finishIndexRun(
        runId: 'persisted-ready',
        status: SearchIndexRunStatus.ready,
        indexedCount: 42,
        totalCount: 42,
        completedAt: completedAt,
      );
      await repository.upsertStories([
        for (var index = 0; index < 42; index++)
          SearchIndexStory(
            sourceType: 'googleDrive',
            sourceId: 'drive-root',
            remoteId: 'story-$index',
            title: 'Story $index',
            lastIndexedAt: completedAt,
          ),
      ]);
      var syncCalls = 0;
      final coordinator = DriveSearchCoordinator(
        repository: repository,
        clock: () => now,
        synchronizeFolder:
            (sourceId, {onProgress, retryFailedExtractions = false}) async {
              syncCalls++;
              return _result(
                sourceId: sourceId,
                status: SearchIndexRunStatus.ready,
                indexedCount: 42,
              );
            },
      );

      await coordinator.restoreState(const ['drive-root']);

      expect(coordinator.state.status, SearchIndexStatus.ready);
      expect(coordinator.state.indexedCount, 42);
      expect(coordinator.state.totalCount, 42);
      expect(coordinator.state.lastIndexedAt, completedAt);

      await coordinator.synchronize(const ['drive-root']);
      expect(syncCalls, 0);
    },
  );

  test('reports partial when only some Drive roots synchronize', () async {
    final coordinator = DriveSearchCoordinator(
      repository: repository,
      synchronizeFolder:
          (sourceId, {onProgress, retryFailedExtractions = false}) async {
            if (sourceId == 'failed-root') {
              return _result(
                sourceId: sourceId,
                status: SearchIndexRunStatus.error,
                indexedCount: 0,
                errorCode: 'sync_failed',
              );
            }
            return _result(
              sourceId: sourceId,
              status: SearchIndexRunStatus.ready,
              indexedCount: 8,
            );
          },
    );

    await coordinator.restoreState(const ['ready-root', 'failed-root']);
    await coordinator.synchronize(const ['ready-root', 'failed-root']);

    expect(coordinator.state.status, SearchIndexStatus.partial);
    expect(coordinator.state.indexedCount, 8);
    expect(coordinator.state.completedSources, 2);
    expect(coordinator.state.totalSources, 2);
    expect(coordinator.state.errorCode, 'sync_failed');
  });

  test('coalesces concurrent background synchronization requests', () async {
    final resultCompleter = Completer<DriveMetadataIndexResult>();
    var callCount = 0;
    final coordinator = DriveSearchCoordinator(
      repository: repository,
      synchronizeFolder:
          (sourceId, {onProgress, retryFailedExtractions = false}) {
            callCount++;
            return resultCompleter.future;
          },
    );

    await coordinator.restoreState(const ['drive-root']);
    final first = coordinator.synchronize(const ['drive-root']);
    final second = coordinator.synchronize(const ['drive-root']);

    expect(identical(first, second), isTrue);
    expect(callCount, 1);

    resultCompleter.complete(
      _result(
        sourceId: 'drive-root',
        status: SearchIndexRunStatus.ready,
        indexedCount: 3,
      ),
    );
    await Future.wait([first, second]);

    expect(callCount, 1);
    expect(coordinator.state.status, SearchIndexStatus.ready);
    expect(coordinator.state.indexedCount, 3);
  });

  test('queues a newly configured root behind the active sync', () async {
    final firstResult = Completer<DriveMetadataIndexResult>();
    final calls = <String>[];
    final coordinator = DriveSearchCoordinator(
      repository: repository,
      synchronizeFolder:
          (sourceId, {onProgress, retryFailedExtractions = false}) {
            calls.add(sourceId);
            if (sourceId == 'first-root' && calls.length == 1) {
              return firstResult.future;
            }
            return Future.value(
              _result(
                sourceId: sourceId,
                status: SearchIndexRunStatus.ready,
                indexedCount: 4,
              ),
            );
          },
    );

    await coordinator.restoreState(const ['first-root']);
    final first = coordinator.synchronize(const ['first-root']);
    final queued = coordinator.synchronize(const ['first-root', 'new-root']);

    expect(identical(first, queued), isTrue);
    expect(calls, ['first-root']);

    firstResult.complete(
      _result(
        sourceId: 'first-root',
        status: SearchIndexRunStatus.ready,
        indexedCount: 3,
      ),
    );
    await Future.wait([first, queued]);

    expect(calls, ['first-root', 'new-root']);
    expect(coordinator.state.status, SearchIndexStatus.ready);
    expect(coordinator.state.indexedCount, 7);
    expect(coordinator.state.totalSources, 2);
  });

  test('late progress cannot overwrite a completed source', () async {
    DriveIndexProgressCallback? callback;
    final coordinator = DriveSearchCoordinator(
      repository: repository,
      synchronizeFolder:
          (sourceId, {onProgress, retryFailedExtractions = false}) async {
            callback = onProgress;
            onProgress!(
              const DriveIndexProgress(
                indexedCount: 2,
                totalCount: 3,
                metadataChanged: true,
              ),
            );
            return _result(
              sourceId: sourceId,
              status: SearchIndexRunStatus.ready,
              indexedCount: 3,
            );
          },
    );
    addTearDown(coordinator.dispose);
    await coordinator.synchronize(['root']);
    callback!(
      const DriveIndexProgress(
        indexedCount: 1,
        totalCount: 3,
        metadataChanged: true,
      ),
    );
    expect(coordinator.state.indexedCount, 3);
    expect(coordinator.state.status, SearchIndexStatus.ready);
    expect(coordinator.state.dataRevision, 1);
  });

  test(
    'manual retry queues once behind a scan and is not reused by later scans',
    () async {
      final first = Completer<DriveMetadataIndexResult>();
      final retry = Completer<DriveMetadataIndexResult>();
      final retryStarted = Completer<void>();
      final calls = <bool>[];
      final coordinator = DriveSearchCoordinator(
        repository: repository,
        synchronizeFolder:
            (sourceId, {onProgress, retryFailedExtractions = false}) {
              calls.add(retryFailedExtractions);
              if (calls.length == 1) return first.future;
              if (calls.length == 2) {
                retryStarted.complete();
                return retry.future;
              }
              return Future.value(
                _result(
                  sourceId: sourceId,
                  status: SearchIndexRunStatus.partial,
                  indexedCount: 1,
                ),
              );
            },
      );
      addTearDown(coordinator.dispose);
      await coordinator.restoreState(['root']);
      final active = coordinator.synchronize(['root'], force: true);
      final queued = coordinator.synchronize([
        'root',
      ], retryFailedExtractions: true);
      final duplicate = coordinator.synchronize([
        'root',
      ], retryFailedExtractions: true);
      expect(identical(active, queued), isTrue);
      expect(identical(queued, duplicate), isTrue);
      first.complete(
        _result(
          sourceId: 'root',
          status: SearchIndexRunStatus.partial,
          indexedCount: 1,
        ),
      );
      await retryStarted.future;
      final duringRetry = coordinator.synchronize([
        'root',
      ], retryFailedExtractions: true);
      retry.complete(
        _result(
          sourceId: 'root',
          status: SearchIndexRunStatus.partial,
          indexedCount: 1,
        ),
      );
      await Future.wait([active, queued, duplicate, duringRetry]);
      expect(calls, [false, true]);
      await coordinator.synchronize(['root'], force: true);
      expect(calls, [false, true, false]);
    },
  );

  test('worker exceptions retain already-published counts', () async {
    final coordinator = DriveSearchCoordinator(
      repository: repository,
      synchronizeFolder:
          (sourceId, {onProgress, retryFailedExtractions = false}) async {
            onProgress!(
              const DriveIndexProgress(
                indexedCount: 2,
                totalCount: null,
                metadataChanged: true,
              ),
            );
            throw StateError('Injected failure after publication');
          },
    );
    addTearDown(coordinator.dispose);
    await coordinator.synchronize(['root']);
    expect(coordinator.state.status, SearchIndexStatus.error);
    expect(coordinator.state.indexedCount, 2);
    expect(coordinator.state.totalCount, isNull);
    expect(coordinator.state.errorCode, 'source_sync_failed');
  });
}

DriveMetadataIndexResult _result({
  required String sourceId,
  required SearchIndexRunStatus status,
  required int indexedCount,
  String? errorCode,
}) {
  return DriveMetadataIndexResult(
    runId: 'run-$sourceId',
    sourceId: sourceId,
    status: status,
    indexedCount: indexedCount,
    totalCount: indexedCount,
    writtenCount: indexedCount,
    unchangedCount: 0,
    deletedCount: 0,
    warningCount: 0,
    errorCode: errorCode,
  );
}
