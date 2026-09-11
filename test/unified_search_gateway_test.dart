import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/models/search_capabilities.dart';
import 'package:online_story_reader/models/search_index_page.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/models/source_models.dart';
import 'package:online_story_reader/models/unified_search.dart';
import 'package:online_story_reader/services/database/database_service.dart';
import 'package:online_story_reader/services/search/drive_search_coordinator.dart';
import 'package:online_story_reader/services/search/extension_search_runner.dart';
import 'package:online_story_reader/services/search/local_library_search_index.dart';
import 'package:online_story_reader/services/search/search_index_repository.dart';
import 'package:online_story_reader/services/search/unified_search_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late DatabaseService database;
  late SearchIndexRepository repository;
  late AppUnifiedSearchGateway gateway;
  late _Drive drive;
  final extensionCalls = <({String id, String query, int page})>[];
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vbook-search-routing-');
    database = DatabaseService(
      factory: databaseFactoryFfi,
      pathResolver: () async => path.join(directory.path, 'index.db'),
    );
    repository = SearchIndexRepository(database);
    drive = _Drive();
    extensionCalls.clear();
    gateway = AppUnifiedSearchGateway(
      drive: drive,
      library: LocalLibrarySearchIndex(
        repository: repository,
        loadStories: () async => [],
      ),
      loadPlugins: () async => [_plugin('novel'), _plugin('comic')],
      extensions: ExtensionSearchRunner(
        execute: (plugin, query, page) async {
          extensionCalls.add((id: plugin.id, query: query, page: page));
          final story = SManga.create()
            ..url = '/story'
            ..title = 'Online book'
            ..author = 'Author'
            ..genre = 'Novel, Fantasy'
            ..description = 'Description'
            ..thumbnailUrl = 'https://example.invalid/cover.png';
          return MangasPage([story], true);
        },
      ),
    );
  });
  tearDown(() async {
    drive.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'only novel sources are included; effective filters reflect actual bridge support',
    () async {
      final sources = await gateway.loadSources();
      expect(sources.map((s) => s.type), [
        SearchSourceType.drive,
        SearchSourceType.local,
        SearchSourceType.extension,
      ]);
      expect(sources.last.capabilities.supportsKeyword, isTrue);
      expect(sources.last.capabilities.supportsPagination, isTrue);
      expect(sources.last.plugin!.searchCapabilities.supportsAuthor, isTrue);
      expect(sources.last.capabilities.supportsAuthor, isFalse);
      expect(sources.last.capabilities.supportsGenre, isFalse);
      expect((await gateway.facets(sources.last)).genres, isEmpty);
    },
  );

  test(
    'Drive routes to SQL pagination and preserves identity, metadata and cover fallback',
    () async {
      drive.items = [
        SearchIndexStory(
          sourceType: 'googleDrive',
          sourceId: 'root',
          remoteId: 'record',
          driveFileId: 'file',
          title: 'Drive book',
          authors: ['Author'],
          genres: ['Novel'],
          description: 'Summary',
          coverLocalPath: ' ',
          coverUrl: 'https://example.invalid/cover.png',
          mimeType: 'application/epub+zip',
          lastIndexedAt: DateTime.utc(2026),
        ),
      ];
      final page = await gateway.search(
        AppUnifiedSearchGateway.driveSource,
        const UnifiedSearchQuery(
          text: 'book',
          author: 'Author',
          genre: 'Novel',
        ),
        2,
        isCurrent: () => true,
      );
      expect(drive.lastOffset, 30);
      expect(drive.lastLimit, 30);
      expect(drive.lastQuery, 'book');
      expect(drive.lastAuthors, ['Author']);
      expect(drive.lastGenres, ['Novel']);
      expect(page.nextPage, 3);
      final result = page.items.single;
      expect(result.remoteId, 'file');
      expect(result.story.id, 'record');
      expect(result.story.driveFileId, 'file');
      expect(result.story.isFromDrive, isTrue);
      expect(result.story.fileType, 'epub');
      expect(result.cover, 'https://example.invalid/cover.png');
      expect(result.author, 'Author');
      expect(result.genres, ['Novel']);
      expect(result.description, 'Summary');
      expect(extensionCalls, isEmpty);
    },
  );

  test(
    'extension results preserve plugin routes and never populate the SQLite catalog',
    () async {
      final source = (await gateway.loadSources()).last;
      final result = await gateway.search(
        source,
        const UnifiedSearchQuery(text: '  book  '),
        2,
        isCurrent: () => true,
      );
      expect(extensionCalls.single, (id: 'novel', query: 'book', page: 2));
      expect(result.nextPage, 3);
      expect(result.items.single.story.pluginId, 'novel');
      expect(result.items.single.story.storyUrl, '/story');
      expect(result.items.single.title, 'Online book');
      expect(result.items.single.genres, ['Novel', 'Fantasy']);
      expect(
        (await repository.searchByKeyword(query: 'Online')).items,
        isEmpty,
      );
    },
  );

  test(
    'unsupported extension filters are rejected before any runner call',
    () async {
      final source = (await gateway.loadSources()).last;
      await expectLater(
        gateway.search(
          source,
          const UnifiedSearchQuery(text: 'book', genre: 'Novel'),
          1,
          isCurrent: () => true,
        ),
        throwsUnsupportedError,
      );
      expect(extensionCalls, isEmpty);
    },
  );
}

PluginInfo _plugin(String type) => PluginInfo(
  id: type,
  name: type,
  author: '',
  source: 'https://example.invalid',
  iconUrl: '',
  description: '',
  type: type,
  locale: 'vi',
  version: 1,
  downloadUrl: '',
  searchCapabilities: SearchCapabilities(
    supportsKeyword: true,
    supportsPagination: true,
    supportsAuthor: true,
    supportsGenre: true,
  ),
);

class _Drive extends ChangeNotifier implements DriveSearchGateway {
  List<SearchIndexStory> items = [];
  int? lastOffset;
  int? lastLimit;
  String? lastQuery;
  List<String>? lastAuthors;
  List<String>? lastGenres;
  @override
  DriveSearchIndexState get state => const DriveSearchIndexState.notStarted();
  @override
  Future<void> restoreState(Iterable<String> folderInputs) async {}
  @override
  Future<void> synchronize(
    Iterable<String> folderInputs, {
    bool force = false,
    bool retryFailedExtractions = false,
  }) async {}
  @override
  Future<List<String>> loadAuthors() async => ['Author'];
  @override
  Future<List<String>> loadGenres() async => ['Novel'];
  @override
  Future<SearchIndexPage> search({
    String query = '',
    Iterable<String> authors = const [],
    Iterable<String> genres = const [],
    int limit = 30,
    int offset = 0,
  }) async {
    lastOffset = offset;
    lastLimit = limit;
    lastQuery = query;
    lastAuthors = authors.toList();
    lastGenres = genres.toList();
    return SearchIndexPage(
      items: items,
      limit: limit,
      offset: offset,
      hasMore: true,
    );
  }
}
