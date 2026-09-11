import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:online_story_reader/models/drive_metadata.dart';
import 'package:online_story_reader/models/search_index_state.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/services/database/database_service.dart';
import 'package:online_story_reader/services/google_drive_service.dart';
import 'package:online_story_reader/services/search/book_metadata_extractor.dart';
import 'package:online_story_reader/services/search/drive_metadata_indexer.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';
import 'package:online_story_reader/services/search/txt_metadata_extractor.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late DatabaseService database;
  late SearchIndexRepository repository;
  late List<DriveMetadataRecord> records;
  var calls = 0;
  var run = 0;
  var fail = true;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vbook-manual-retry-');
    database = DatabaseService(
      factory: databaseFactoryFfi,
      pathResolver: () async => path.join(directory.path, 'index.db'),
    );
    repository = SearchIndexRepository(database);
    records = [_record('application/epub+zip')];
    calls = 0;
    run = 0;
    fail = true;
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  DriveMetadataIndexer worker() => DriveMetadataIndexer(
    repository: repository,
    folderIdParser: (input) => input,
    snapshotLoader: (root) async => DriveMetadataSnapshot(
      sourceId: root,
      records: records,
      traversalComplete: true,
    ),
    runIdFactory: () => 'manual-${++run}',
    txtMetadataLoader: (_) async {
      calls++;
      if (fail) throw const SocketException('Test transport failure');
      return const TxtMetadata(title: 'Recovered title');
    },
    epubMetadataLoader: (_) async {
      calls++;
      if (fail) throw const SocketException('Test transport failure');
      return const BookMetadata(title: 'Recovered title');
    },
  );

  Future<SearchIndexJobUpdate> job([
    String root = 'root',
    String id = 'book',
  ]) async => (await repository.loadIndexJobsForSource(
    sourceType: 'googleDrive',
    sourceId: root,
  ))[id]!;

  for (final mime in ['text/plain', 'application/epub+zip']) {
    test(
      '$mime explicit retry grants one attempt, not a new automatic budget',
      () async {
        records = [_record(mime)];
        final indexer = worker();
        for (var i = 0; i < 4; i++) {
          await indexer.synchronizeFolder('root');
        }
        expect(calls, 3);
        expect((await job()).attempts, 3);
        final failed = await indexer.synchronizeFolder(
          'root',
          retryFailedExtractions: true,
        );
        expect(calls, 4);
        expect((await job()).attempts, 4);
        expect((await job()).status, SearchIndexJobStatus.error);
        expect(failed.indexedCount, 1);
        expect(
          (await repository.searchByTitle('Fallback')).items,
          hasLength(1),
        );
        await database.close();
        await worker().synchronizeFolder('root');
        expect(
          calls,
          4,
          reason: 'Restart must not silently retry past the budget',
        );
        fail = false;
        await worker().synchronizeFolder('root', retryFailedExtractions: true);
        expect(calls, 5);
        expect((await job()).attempts, 5);
        expect((await job()).status, SearchIndexJobStatus.complete);
        expect(
          (await repository.searchByTitle('Recovered')).items,
          hasLength(1),
        );
        await worker().synchronizeFolder('root', retryFailedExtractions: true);
        expect(
          calls,
          5,
          reason:
              'Manual retry must not redownload successful partial metadata',
        );
      },
    );
  }

  test(
    'explicit retry is source scoped and revision changes reset normal attempts',
    () async {
      final indexer = worker();
      for (final root in ['root', 'other-root']) {
        records = [
          _record(
            'application/epub+zip',
            id: root == 'root' ? 'book' : 'other-book',
          ),
        ];
        for (var i = 0; i < 3; i++) {
          final result = await indexer.synchronizeFolder(root);
          expect(result.status, SearchIndexRunStatus.partial);
        }
      }
      expect(calls, 6);
      records = [_record('application/epub+zip')];
      await indexer.synchronizeFolder('root', retryFailedExtractions: true);
      expect((await job()).attempts, 4);
      expect((await job('other-root', 'other-book')).attempts, 3);
      records = [_record('application/epub+zip', checksum: 'changed')];
      await indexer.synchronizeFolder('root');
      expect((await job()).attempts, 1);
      expect(calls, 8);
    },
  );

  test('manual retry cannot bypass size or revision evidence guards', () async {
    records = [
      _record(
        'application/epub+zip',
        size: GoogleDriveService.epubMetadataMaxBytes + 1,
      ),
    ];
    await worker().synchronizeFolder('root', retryFailedExtractions: true);
    expect((await job()).errorCode, 'epub_size_limit');
    expect(calls, 0);
    records = [_record('text/plain', checksum: null)];
    await worker().synchronizeFolder('root', retryFailedExtractions: true);
    expect((await job()).status, SearchIndexJobStatus.pending);
    expect(calls, 0);
  });
}

DriveMetadataRecord _record(
  String mime, {
  String id = 'book',
  String? checksum = 'revision',
  int size = 1024,
}) => DriveMetadataRecord(
  driveFileId: id,
  fileName: 'Fallback',
  title: 'Fallback title',
  mimeType: mime,
  checksum: checksum,
  fileSize: size,
  metadataStatus: SearchMetadataStatus.missing,
  origin: DriveMetadataOrigin.driveFile,
);
