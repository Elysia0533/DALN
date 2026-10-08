import 'dart:io';

import 'package:flutter/foundation.dart';
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

  test(
    '5000 metadata records retain bounded writes, deep search and stable paging after restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vbook-search-benchmark-',
      );
      final databasePath = path.join(directory.path, 'index.db');
      DatabaseService open() => DatabaseService(
        factory: databaseFactoryFfi,
        pathResolver: () async => databasePath,
      );
      var database = open();
      addTearDown(() async {
        await database.close();
        await directory.delete(recursive: true);
      });
      var repository = _MeasuredRepository(database);
      var now = DateTime.utc(2026, 9, 7);
      var run = 0;
      var snapshotCalls = 0;
      final snapshot = DriveMetadataSnapshot(
        sourceId: 'benchmark-root',
        traversalComplete: true,
        records: [
          for (var i = 0; i < 5000; i++)
            DriveMetadataRecord(
              driveFileId: 'file-$i',
              fileName: '$i.epub',
              title: 'Truyện ${i.toString().padLeft(4, '0')}',
              mimeType: 'application/epub+zip',
              modifiedTime: DateTime.utc(2026),
              checksum: 'revision-$i',
              fileSize: 4096,
              authors: ['Tác giả ${i % 40}'],
              genres: ['Thể loại ${i % 20}', 'Tiểu thuyết'],
              metadataStatus: SearchMetadataStatus.complete,
              origin: DriveMetadataOrigin.catalog,
            ),
        ],
      );
      DriveMetadataIndexer indexer() => DriveMetadataIndexer(
        repository: repository,
        snapshotLoader: (_) async {
          snapshotCalls++;
          return snapshot;
        },
        folderIdParser: (input) => input,
        clock: () => now,
        runIdFactory: () => 'benchmark-${++run}',
      );

      final indexing = Stopwatch()..start();
      final first = await indexer().synchronizeFolder('benchmark-root');
      indexing.stop();
      expect(first.indexedCount, 5000);
      expect(first.status, SearchIndexRunStatus.ready);
      expect(repository.batchSizes, hasLength(50));
      expect(
        repository.batchSizes.every(
          (size) => size <= SearchIndexRepository.maxUpsertBatchSize,
        ),
        isTrue,
      );
      final indexedAt = (await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'benchmark-root',
        remoteId: 'file-4000',
      ))!.lastIndexedAt;

      await database.close();
      database = open();
      repository = _MeasuredRepository(database);
      now = now.add(const Duration(days: 1));
      final rescan = Stopwatch()..start();
      final second = await indexer().synchronizeFolder('benchmark-root');
      rescan.stop();
      expect(second.writtenCount, 0);
      expect(second.unchangedCount, 5000);
      expect(repository.batchSizes, isEmpty);
      expect(
        (await repository.findByIdentity(
          sourceType: 'googleDrive',
          sourceId: 'benchmark-root',
          remoteId: 'file-4000',
        ))!.lastIndexedAt,
        indexedAt,
      );

      final samples = <int>[];
      for (var i = 0; i < 20; i++) {
        final timer = Stopwatch()..start();
        final result = await repository.searchByKeyword(
          query: 'truyen 4000',
          sourceType: 'googleDrive',
          sourceId: 'benchmark-root',
          limit: 30,
        );
        timer.stop();
        samples.add(timer.elapsedMicroseconds);
        expect(result.items.single.remoteId, 'file-4000');
        expect(result.items.single.title, 'Truyện 4000');
        expect(result.hasMore, isFalse);
      }
      final combined = await repository.searchCombined(
        query: 'truyen 4000',
        authors: ['tac gia 0'],
        genres: ['the loai 0', 'tieu thuyet'],
        sourceType: 'googleDrive',
        sourceId: 'benchmark-root',
      );
      expect(combined.items.single.remoteId, 'file-4000');
      expect(
        (await repository.searchByKeyword(
          query: "%' OR 1=1 --",
          limit: 30,
        )).items,
        isEmpty,
      );
      expect(
        (await repository.listAuthors(
          sourceType: 'googleDrive',
          sourceId: 'benchmark-root',
        )),
        hasLength(40),
      );
      expect(
        (await repository.listGenres(
          sourceType: 'googleDrive',
          sourceId: 'benchmark-root',
        )),
        hasLength(21),
      );

      final paging = Stopwatch()..start();
      final identities = <String>{};
      var offset = 0;
      while (true) {
        final page = await repository.searchByKeyword(
          query: 'truyen',
          sourceType: 'googleDrive',
          sourceId: 'benchmark-root',
          limit: 30,
          offset: offset,
        );
        expect(page.items.length, lessThanOrEqualTo(30));
        for (final story in page.items) {
          expect(identities.add(story.remoteId), isTrue);
        }
        if (!page.hasMore) break;
        expect(page.nextOffset, greaterThan(offset));
        offset = page.nextOffset!;
      }
      paging.stop();
      expect(identities, hasLength(5000));
      expect(
        snapshotCalls,
        2,
        reason:
            'SQL queries and paging must not invoke a Drive snapshot request.',
      );
      final foreignKeys = await (await database.database).rawQuery(
        'PRAGMA foreign_key_check',
      );
      expect(foreignKeys, isEmpty);
      final schema = await (await database.database).rawQuery(
        'PRAGMA table_info(stories)',
      );
      expect(schema.map((row) => row['name']), isNot(contains('content')));
      samples.sort();
      // Record a local baseline, not a hardware-dependent timing gate or an
      // Android/quota measurement. Network snapshots above are synthetic fixtures.
      debugPrint(
        '[SEARCH_BENCH] rows=5000 insert_ms=${indexing.elapsedMilliseconds} '
        'unchanged_rescan_ms=${rescan.elapsedMilliseconds} query_p50_us=${samples[9]} '
        'query_p95_us=${samples[18]} all_pages_ms=${paging.elapsedMilliseconds}',
      );
    },
  );
}

class _MeasuredRepository extends SearchIndexRepository {
  _MeasuredRepository(super.databaseService);
  final batchSizes = <int>[];

  @override
  Future<void> upsertStories(Iterable<SearchIndexStory> stories) {
    final batch = stories.toList(growable: false);
    batchSizes.add(batch.length);
    return super.upsertStories(batch);
  }
}
