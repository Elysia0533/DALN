import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:online_story_reader/models/search_index_state.dart';
import 'package:online_story_reader/models/story.dart';
import 'package:online_story_reader/services/database/database_service.dart';
import 'package:online_story_reader/services/google_drive_service.dart';
import 'package:online_story_reader/services/search/drive_metadata_indexer.dart';
import 'package:online_story_reader/services/search/drive_search_coordinator.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';
import 'package:online_story_reader/services/search/txt_metadata_extractor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late DatabaseService database;
  late SearchIndexRepository repository;
  late MockClient client;
  late Map<String, Object?> liveFile;
  late Map<String, Object?> catalogEntry;
  late List<Map<String, Object?>> files;
  late int extractionCalls;
  late int listingCalls;
  late int run;
  late bool offline;

  void openDatabase() {
    database = DatabaseService(
      factory: databaseFactoryFfi,
      pathResolver: () async => path.join(directory.path, 'index.db'),
    );
    repository = SearchIndexRepository(database);
  }

  DriveMetadataIndexer indexer() => DriveMetadataIndexer(
    repository: repository,
    snapshotLoader: (root) =>
        GoogleDriveService.fetchMetadataIndexSnapshotForTesting(
          client: client,
          rootFolderId: root,
        ),
    folderIdParser: (input) => input,
    runIdFactory: () => 'provenance-${++run}',
    txtMetadataLoader: (_) async {
      extractionCalls++;
      return TxtMetadataExtractor.parse(
        Uint8List.fromList(
          utf8.encode(
            'Title: Current extracted title\nAuthor: Current author\n'
            'Genre: Current genre\nChapter 1: Beginning\n',
          ),
        ),
      );
    },
  );

  DriveSearchCoordinator coordinator() => DriveSearchCoordinator(
    repository: repository,
    synchronizeFolder: indexer().synchronizeFolder,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'vbook-cache-provenance-',
    );
    openDatabase();
    extractionCalls = 0;
    listingCalls = 0;
    run = 0;
    offline = false;
    SharedPreferences.setMockInitialValues({});
    liveFile = {
      'id': 'story',
      'name': 'File.txt',
      'mimeType': 'text/plain',
      'md5Checksum': 'revision-one',
      'modifiedTime': '2026-09-01T00:00:00Z',
      'size': '1024',
    };
    catalogEntry = {
      'driveFileId': 'story',
      'title': 'Original published title',
      'authors': ['Original author'],
      'genres': ['Original genre'],
      'checksum': 'revision-one',
      'modifiedTime': '2026-09-01T00:00:00Z',
      'size': 1024,
      'metadataStatus': 'complete',
    };
    files = [
      liveFile,
      {
        'id': 'catalog',
        'name': 'catalog.vbook.json',
        'mimeType': 'application/json',
      },
    ];
    client = MockClient((request) async {
      if (offline) throw const SocketException('offline');
      if (request.url.queryParameters['alt'] == 'media') {
        expect(request.url.pathSegments.last, 'catalog');
        return http.Response(
          jsonEncode({
            'schemaVersion': 1,
            'source': {'rootFolderId': 'root'},
            'stories': [catalogEntry],
          }),
          200,
        );
      }
      listingCalls++;
      return http.Response(jsonEncode({'files': files}), 200);
    });
  });

  tearDown(() async {
    client.close();
    await database.close();
    await directory.delete(recursive: true);
  });

  test('changed live revision bypasses stale complete catalog and reuses '
      'the new extraction after DB reopening', () async {
    final first = await indexer().synchronizeFolder('root');
    expect(first.status, SearchIndexRunStatus.ready);
    expect(extractionCalls, 0);
    expect((await repository.searchByAuthor('Original')).items, hasLength(1));

    liveFile['md5Checksum'] = 'revision-two';
    liveFile['modifiedTime'] = '2026-09-10T00:00:00Z';
    final updated = await indexer().synchronizeFolder('root');
    expect(updated.status, SearchIndexRunStatus.partial);
    expect(updated.warningCount, 1);
    expect(extractionCalls, 1);
    expect((await repository.searchByAuthor('Original')).items, isEmpty);
    expect(
      (await repository.searchByAuthor('Current')).items.single.title,
      'Current extracted title',
    );
    final stored = await repository.findByIdentity(
      sourceType: 'googleDrive',
      sourceId: 'root',
      remoteId: 'story',
    );
    expect(stored!.checksum, 'revision-two');

    await database.close();
    openDatabase();
    final repeated = await indexer().synchronizeFolder('root');
    expect(repeated.status, SearchIndexRunStatus.partial);
    expect(repeated.writtenCount, 0);
    expect(repeated.unchangedCount, 1);
    expect(extractionCalls, 1);
    expect(
      (await repository.findByIdentity(
        sourceType: 'googleDrive',
        sourceId: 'root',
        remoteId: 'story',
      ))!.lastIndexedAt,
      stored.lastIndexedAt,
    );
  });

  test('catalog-only revision never authorizes a content extraction', () async {
    liveFile.remove('md5Checksum');
    liveFile.remove('modifiedTime');
    liveFile.remove('size');
    catalogEntry['metadataStatus'] = 'partial';
    catalogEntry.remove('authors');
    catalogEntry.remove('genres');

    final result = await indexer().synchronizeFolder('root');
    expect(result.status, SearchIndexRunStatus.partial);
    expect(extractionCalls, 0);
    final stored = await repository.findByIdentity(
      sourceType: 'googleDrive',
      sourceId: 'root',
      remoteId: 'story',
    );
    expect(stored!.checksum, isNull);
    expect(stored.modifiedTime, isNull);
    expect(stored.fileSize, isNull);
    final jobs = await repository.loadIndexJobsForSource(
      sourceType: 'googleDrive',
      sourceId: 'root',
    );
    expect(jobs['story']!.status, SearchIndexJobStatus.pending);
    expect(jobs['story']!.attempts, 0);
  });

  for (final malformed in [false, true]) {
    test('legacy display caches are not search input or modified '
        '(malformed=$malformed)', () async {
      SharedPreferences.setMockInitialValues({
        'drive_story_catalog_cache': [
          malformed
              ? '{invalid json'
              : jsonEncode(
                  Story(
                    id: 'legacy-only',
                    title: 'Legacy display title',
                    author: 'Unverified author',
                    driveFileId: 'legacy-only',
                    isFromDrive: true,
                  ).toJson(),
                ),
        ],
        'drive_story_catalog_cache_at': 1788998400000,
        'drive_story_metadata_cache_v2': malformed
            ? '[broken json'
            : jsonEncode({
                'story': {
                  'title': 'Legacy override',
                  'author': 'Unverified author',
                  'genres': ['Unverified genre'],
                },
              }),
      });
      final prefs = await SharedPreferences.getInstance();
      final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      final gateway = coordinator();
      await gateway.restoreState(['root']);
      expect(gateway.state.status, SearchIndexStatus.notStarted);
      expect((await gateway.search(query: 'Legacy')).items, isEmpty);
      expect(listingCalls, 0);

      await gateway.synchronize(['root']);
      expect(gateway.state.indexedCount, 1);
      expect((await gateway.search(query: 'Legacy')).items, isEmpty);
      expect(
        (await gateway.search(query: 'Original')).items.single.remoteId,
        'story',
      );
      gateway.dispose();
      await database.close();
      openDatabase();
      final restored = coordinator();
      addTearDown(restored.dispose);
      await restored.restoreState(['root']);
      expect((await restored.search(query: 'Original')).items, hasLength(1));
      expect((await restored.search(query: 'Unverified')).items, isEmpty);
      expect(listingCalls, 1);

      offline = true;
      await restored.synchronize(['root'], force: true);
      expect(restored.state.status, SearchIndexStatus.error);
      expect((await restored.search(query: 'Original')).items, hasLength(1));
      expect((await restored.search(query: 'Legacy')).items, isEmpty);
      expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
    });
  }

  test(
    'deleted file is not restored from either catalog or legacy cache',
    () async {
      SharedPreferences.setMockInitialValues({
        'drive_story_catalog_cache': [
          jsonEncode(
            Story(
              id: 'story',
              title: 'Cached book',
              driveFileId: 'story',
            ).toJson(),
          ),
        ],
      });
      await indexer().synchronizeFolder('root');
      files.remove(liveFile);
      final deleted = await indexer().synchronizeFolder('root');
      expect(deleted.deletedCount, 1);
      expect(deleted.warningCount, 1);
      expect(deleted.indexedCount, 0);
      await database.close();
      openDatabase();
      final gateway = coordinator();
      addTearDown(gateway.dispose);
      await gateway.restoreState(['root']);
      expect((await gateway.search()).items, isEmpty);
      expect(
        (await repository.loadIndexJobsForSource(
          sourceType: 'googleDrive',
          sourceId: 'root',
        )),
        isEmpty,
      );
      expect(
        (await SharedPreferences.getInstance()).getStringList(
          'drive_story_catalog_cache',
        ),
        hasLength(1),
      );
    },
  );
}
