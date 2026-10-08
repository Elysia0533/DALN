import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:online_story_reader/models/drive_metadata.dart';
import 'package:online_story_reader/models/search_index_state.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/services/database/database_service.dart';
import 'package:online_story_reader/services/search/drive_metadata_indexer.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';
import 'package:online_story_reader/services/search/txt_metadata_extractor.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late DatabaseService database;
  late SearchIndexRepository repository;
  late List<DriveMetadataRecord> records;
  late TxtMetadataLoader loader;
  late DateTime now;
  var run = 0;
  var calls = 0;

  void open() {
    database = DatabaseService(
      factory: databaseFactoryFfi,
      pathResolver: () async => path.join(directory.path, 'index.db'),
    );
    repository = SearchIndexRepository(database);
  }

  DriveMetadataIndexer indexer() => DriveMetadataIndexer(
    repository: repository,
    snapshotLoader: (id) async => DriveMetadataSnapshot(
      sourceId: id,
      records: records,
      traversalComplete: true,
    ),
    folderIdParser: (id) => id,
    clock: () => now,
    runIdFactory: () => 'txt-${++run}',
    txtMetadataLoader: (id) {
      calls++;
      return loader(id);
    },
  );
  Future<SearchIndexJobUpdate> job([String id = 'one']) async =>
      (await repository.loadIndexJobsForSource(
        sourceType: 'googleDrive',
        sourceId: 'root',
      ))[id]!;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vbook-txt-index-');
    open();
    run = 0;
    calls = 0;
    now = DateTime.utc(2026, 9, 7);
    records = [_record('one')];
    loader = (_) async => TxtMetadataExtractor.parse(
      Uint8List.fromList(
        utf8.encode(
          'Tên truyện: Trời Xanh\nTác giả: Nguyễn An\nThể loại: Tiên Hiệp\n'
          'Chương 1: Khởi đầu\nPRIVATE BOOK BODY NOT FOR SQL',
        ),
      ),
    );
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'new TXT becomes searchable by extracted fields without storing its body',
    () async {
      final result = await indexer().synchronizeFolder('root');
      expect(result.status, SearchIndexRunStatus.ready);
      expect(calls, 1);
      expect(
        (await repository.searchByTitle('troi xanh')).items.single.remoteId,
        'one',
      );
      expect(
        (await repository.searchByAuthor('nguyen an')).items.single.remoteId,
        'one',
      );
      expect(
        (await repository.searchByGenre('tien hiep')).items.single.remoteId,
        'one',
      );
      final stored = await (await database.database).query('stories');
      expect(stored.toString(), isNot(contains('PRIVATE BOOK BODY')));
      expect((await job()).status, SearchIndexJobStatus.complete);
      expect((await job()).attempts, 1);
    },
  );

  test(
    'partial extraction is not downloaded again after reopening the database',
    () async {
      loader = (_) async => const TxtMetadata(title: 'Header title');
      await indexer().synchronizeFolder('root');
      final original = await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'one',
      );
      final originalJob = await job();
      await database.close();
      open();
      now = now.add(const Duration(days: 1));
      final result = await indexer().synchronizeFolder('root');
      expect(calls, 1);
      expect(result.writtenCount, 0);
      expect(result.status, SearchIndexRunStatus.partial);
      expect(
        (await repository.findByIdentity(
          sourceType: 'googleDrive',
          sourceId: 'root',
          remoteId: 'one',
        ))!.lastIndexedAt,
        original!.lastIndexedAt,
      );
      expect((await job()).updatedAt, originalJob.updatedAt);
    },
  );

  test(
    'missing headers retain filename and do not trigger repeated downloads',
    () async {
      loader = (_) async => const TxtMetadata();
      await indexer().synchronizeFolder('root');
      await indexer().synchronizeFolder('root');
      final story = (await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'one',
      ))!;
      expect(story.title, 'Filename one');
      expect(story.authors, isEmpty);
      expect(story.metadataStatus, SearchMetadataStatus.missing);
      expect(calls, 1);
      expect((await job()).status, SearchIndexJobStatus.complete);
    },
  );

  test(
    'complete catalog avoids extraction and partial sidecar fields take priority',
    () async {
      records = [
        _record(
          'complete',
          title: 'Catalog',
          origin: DriveMetadataOrigin.catalog,
          status: SearchMetadataStatus.complete,
        ),
        _record(
          'sidecar',
          title: 'Sidecar title',
          origin: DriveMetadataOrigin.sidecar,
          authors: ['Publisher author'],
        ),
      ];
      await indexer().synchronizeFolder('root');
      expect(calls, 1);
      final story = (await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'sidecar',
      ))!;
      expect(story.title, 'Sidecar title');
      expect(story.authors, ['Publisher author']);
      expect(story.genres, ['Tiên Hiệp']);
    },
  );

  test(
    'changed file revision reextracts once and discards obsolete fields',
    () async {
      await indexer().synchronizeFolder('root');
      records = [_record('one', revision: 'v2')];
      loader = (_) async => const TxtMetadata(title: 'New title');
      await indexer().synchronizeFolder('root');
      await indexer().synchronizeFolder('root');
      expect(calls, 2);
      final story = (await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'one',
      ))!;
      expect(story.title, 'New title');
      expect(story.authors, isEmpty);
      expect(story.genres, isEmpty);
      expect(story.checksum, 'v2');
      expect((await job()).attempts, 1);
    },
  );

  test(
    'per-file failure leaves other results available and persists only a fixed code',
    () async {
      records = [_record('one'), _record('two')];
      loader = (id) async {
        if (id == 'one') {
          throw const FormatException('sensitive transport detail');
        }
        return const TxtMetadata(
          title: 'Working',
          authors: ['Author'],
          genres: ['Novel'],
        );
      };
      final result = await indexer().synchronizeFolder('root');
      expect(result.status, SearchIndexRunStatus.partial);
      expect(result.indexedCount, 2);
      expect(result.warningCount, 1);
      expect(
        (await repository.searchByTitle('Working')).items.single.remoteId,
        'two',
      );
      expect((await job()).errorCode, 'txt_extraction_failed');
      final rows = await (await database.database).query('index_jobs');
      expect(rows.toString(), isNot(contains('sensitive transport detail')));
    },
  );

  test(
    'failed attempts are capped per revision and a changed file starts a new budget',
    () async {
      loader = (_) async => throw const SocketException('offline');
      for (var i = 0; i < 5; i++) {
        await indexer().synchronizeFolder('root');
      }
      expect(calls, DriveMetadataIndexer.maxExtractionAttempts);
      expect((await job()).attempts, 3);
      await database.close();
      open();
      await indexer().synchronizeFolder('root');
      expect(calls, 3);
      records = [_record('one', revision: 'v2')];
      loader = (_) async => const TxtMetadata(title: 'Recovered');
      await indexer().synchronizeFolder('root');
      expect(calls, 4);
      expect((await job()).attempts, 1);
      expect((await job()).errorCode, isNull);
    },
  );

  test('interrupted running extraction can recover on restart', () async {
    loader = (_) async => const TxtMetadata(title: 'Partial');
    await indexer().synchronizeFolder('root');
    await repository.upsertIndexJobs([
      SearchIndexJobUpdate(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'one',
        driveFileId: 'one',
        status: SearchIndexJobStatus.running,
        attempts: 1,
        updatedAt: now,
      ),
    ]);
    await database.close();
    open();
    await indexer().synchronizeFolder('root');
    expect(calls, 2);
    expect((await job()).status, SearchIndexJobStatus.complete);
  });

  test(
    'TXT without revision evidence and other formats remain pending without download',
    () async {
      records = [
        _record('one', revision: null),
        _record('epub', mime: 'application/epub+zip'),
        _record('pdf', mime: 'application/pdf'),
      ];
      final result = await indexer().synchronizeFolder('root');
      expect(calls, 0);
      expect(result.status, SearchIndexRunStatus.partial);
      expect((await job()).status, SearchIndexJobStatus.pending);
    },
  );

  test(
    'at most two TXT loads run concurrently and SQL is not locked during network work',
    () async {
      records = List.generate(5, (i) => _record('$i'));
      var active = 0;
      var maximum = 0;
      final bothStarted = Completer<void>();
      final release = Completer<void>();
      loader = (_) async {
        active++;
        if (active > maximum) maximum = active;
        if (active == 2 && !bothStarted.isCompleted) bothStarted.complete();
        await release.future;
        active--;
        return const TxtMetadata(title: 'Header');
      };
      final sync = indexer().synchronizeFolder('root');
      await bothStarted.future.timeout(const Duration(seconds: 5));
      try {
        await repository
            .searchByKeyword(query: 'Book')
            .timeout(const Duration(seconds: 2));
      } finally {
        release.complete();
      }
      await sync;
      expect(maximum, 2);
      expect(active, 0);
      expect(calls, 5);
    },
  );
}

DriveMetadataRecord _record(
  String id, {
  String? revision = 'v1',
  String mime = 'text/plain',
  String? title,
  DriveMetadataOrigin origin = DriveMetadataOrigin.driveFile,
  SearchMetadataStatus status = SearchMetadataStatus.missing,
  List<String> authors = const [],
}) => DriveMetadataRecord(
  driveFileId: id,
  fileName: '$id.txt',
  title: title ?? 'Filename $id',
  mimeType: mime,
  checksum: revision,
  fileSize: 1000,
  origin: origin,
  metadataStatus: status,
  authors: authors,
);
