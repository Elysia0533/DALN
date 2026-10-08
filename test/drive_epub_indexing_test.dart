import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
import 'package:online_story_reader/services/search/epub_metadata_extractor.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';
import 'package:online_story_reader/services/search/txt_metadata_extractor.dart';

import 'support/epub_metadata_fixture.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late DatabaseService database;
  late SearchIndexRepository repository;
  late List<DriveMetadataRecord> records;
  late BookMetadataLoader loader;
  var calls = 0;
  var run = 0;
  late DateTime now;
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
    runIdFactory: () => 'epub-${++run}',
    epubMetadataLoader: (id) {
      calls++;
      return loader(id);
    },
    txtMetadataLoader: (_) async => const TxtMetadata(),
  );
  Future<SearchIndexJobUpdate> job(String id) async =>
      (await repository.loadIndexJobsForSource(
        sourceType: 'googleDrive',
        sourceId: 'root',
      ))[id]!;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vbook-epub-index-');
    open();
    calls = 0;
    run = 0;
    now = DateTime.utc(2026, 9, 7);
    records = [_record('one')];
    loader = (_) => compute(EpubMetadataExtractor.parse, epubMetadataFixture());
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'EPUB OPF metadata is searchable in SQL and no chapter or cover bytes are persisted',
    () async {
      final result = await indexer().synchronizeFolder('root');
      expect(result.status, SearchIndexRunStatus.ready);
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
      final story = (await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'one',
      ))!;
      expect(story.description, 'A short description.');
      expect(story.coverLocalPath, isNull);
      expect((await job('one')).status, SearchIndexJobStatus.complete);
      expect(
        (await (await database.database).query('stories')).single.keys,
        isNot(anyOf(contains('content'), contains('cover_bytes'))),
      );
    },
  );

  test(
    'unchanged partial OPF is not extracted again after database reopening',
    () async {
      loader = (_) => compute(
        EpubMetadataExtractor.parse,
        epubMetadataFixture(metadata: '<dc:title>Partial title</dc:title>'),
      );
      await indexer().synchronizeFolder('root');
      final initial = (await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'one',
      ))!;
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
        initial.lastIndexedAt,
      );
    },
  );

  test(
    'catalog fields win and a complete catalog never invokes the EPUB loader',
    () async {
      records = [
        _record(
          'complete',
          status: SearchMetadataStatus.complete,
          origin: DriveMetadataOrigin.catalog,
        ),
        _record(
          'partial',
          origin: DriveMetadataOrigin.sidecar,
          title: 'Publisher title',
          authors: ['Publisher'],
          description: 'Publisher description',
        ),
      ];
      await indexer().synchronizeFolder('root');
      expect(calls, 1);
      final story = (await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'partial',
      ))!;
      expect(story.title, 'Publisher title');
      expect(story.authors, ['Publisher']);
      expect(story.description, 'Publisher description');
      expect(story.genres, ['Tiên Hiệp']);
    },
  );

  test(
    'a changed EPUB resets extraction and removes obsolete OPF fields',
    () async {
      await indexer().synchronizeFolder('root');
      records = [_record('one', revision: 'v2')];
      loader = (_) async => const BookMetadata(title: 'Changed');
      await indexer().synchronizeFolder('root');
      await indexer().synchronizeFolder('root');
      expect(calls, 2);
      final story = (await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'one',
      ))!;
      expect(story.title, 'Changed');
      expect(story.authors, isEmpty);
      expect(story.description, isEmpty);
      expect(story.genres, isEmpty);
      expect((await job('one')).attempts, 1);
    },
  );

  test(
    'MIME correction selects EPUB extraction even with the same file checksum',
    () async {
      records = [_record('one', mime: 'text/plain')];
      await indexer().synchronizeFolder('root');
      expect((await job('one')).status, SearchIndexJobStatus.complete);
      records = [_record('one')];
      await indexer().synchronizeFolder('root');
      expect(calls, 1);
      expect(
        (await repository.findByIdentity(
          sourceType: 'googleDrive',
          sourceId: 'root',
          remoteId: 'one',
        ))!.title,
        'Trời Xanh',
      );
    },
  );

  test(
    'known oversized EPUB and files without revision evidence do not download',
    () async {
      records = [
        _record('large', size: GoogleDriveService.epubMetadataMaxBytes + 1),
        _record('unknown', revision: null),
        _record('pdf', mime: 'application/pdf'),
      ];
      final result = await indexer().synchronizeFolder('root');
      expect(calls, 0);
      expect(result.status, SearchIndexRunStatus.partial);
      expect(result.indexedCount, 3);
      expect((await job('large')).errorCode, 'epub_size_limit');
      expect((await job('large')).attempts, 0);
      expect((await job('unknown')).status, SearchIndexJobStatus.pending);
    },
  );

  test(
    'malformed EPUB does not stop another book and stores only a fixed error code',
    () async {
      records = [_record('one'), _record('two')];
      loader = (id) => compute(
        EpubMetadataExtractor.parse,
        id == 'one'
            ? epubMetadataFixture(opf: '<sensitive-book-text>')
            : epubMetadataFixture(),
      );
      final result = await indexer().synchronizeFolder('root');
      expect(result.status, SearchIndexRunStatus.partial);
      expect(result.indexedCount, 2);
      expect((await job('one')).errorCode, 'epub_extraction_failed');
      expect(
        (await repository.searchByAuthor('nguyen an')).items.single.remoteId,
        'two',
      );
      expect(
        (await (await database.database).query('index_jobs')).toString(),
        isNot(contains('sensitive-book-text')),
      );
    },
  );

  test(
    'failed EPUB attempt budget survives reopening and resets on revision change',
    () async {
      loader = (_) async => throw const SocketException('offline');
      for (var i = 0; i < 4; i++) {
        await indexer().synchronizeFolder('root');
      }
      await database.close();
      open();
      await indexer().synchronizeFolder('root');
      expect(calls, 3);
      records = [_record('one', revision: 'v2')];
      loader = (_) async => const BookMetadata(title: 'Recovered');
      await indexer().synchronizeFolder('root');
      expect(calls, 4);
      expect((await job('one')).errorCode, isNull);
    },
  );

  test(
    'an interrupted EPUB job can recover and deletion still removes its job',
    () async {
      loader = (_) async => const BookMetadata(title: 'Partial');
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
      records = [];
      expect((await indexer().synchronizeFolder('root')).deletedCount, 1);
      expect(
        await repository.loadIndexJobsForSource(
          sourceType: 'googleDrive',
          sourceId: 'root',
        ),
        isEmpty,
      );
    },
  );

  test(
    'shared metadata limiter caps mixed work at two and releases failed permits',
    () async {
      var active = 0;
      var maximum = 0;
      final started = Completer<void>();
      final release = Completer<void>();
      final tasks = List.generate(
        5,
        (i) => BookMetadataExtraction.run(() async {
          active++;
          if (active > maximum) maximum = active;
          if (active == 2 && !started.isCompleted) started.complete();
          await release.future;
          active--;
          if (i == 0) throw const FormatException('controlled');
          return i;
        }).then((_) => true, onError: (_) => false),
      );
      await started.future.timeout(const Duration(seconds: 5));
      expect(active, 2);
      release.complete();
      final outcomes = await Future.wait(tasks);
      expect(outcomes.where((ok) => !ok), hasLength(1));
      expect(maximum, 2);
      expect(active, 0);
    },
  );
}

DriveMetadataRecord _record(
  String id, {
  String? revision = 'v1',
  int size = 4096,
  String mime = 'application/epub+zip',
  String? title,
  List<String> authors = const [],
  String description = '',
  DriveMetadataOrigin origin = DriveMetadataOrigin.driveFile,
  SearchMetadataStatus status = SearchMetadataStatus.missing,
}) => DriveMetadataRecord(
  driveFileId: id,
  fileName: '$id.epub',
  title: title ?? 'Filename $id',
  mimeType: mime,
  fileSize: size,
  checksum: revision,
  authors: authors,
  description: description,
  origin: origin,
  metadataStatus: status,
);
