import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/models/search_index_page.dart';
import 'package:online_story_reader/models/search_index_state.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/models/story.dart';
import 'package:online_story_reader/screens/explore_screen.dart';
import 'package:online_story_reader/screens/unified_search_screen.dart';
import 'package:online_story_reader/services/admin_claim_reader.dart';
import 'package:online_story_reader/services/google_drive_service.dart';
import 'package:online_story_reader/services/search/drive_search_coordinator.dart';
import 'package:online_story_reader/theme/user_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('rapid refresh calls share one in-flight Drive request', (
    tester,
  ) async {
    final harness = _DriveLoaderHarness();
    await tester.pumpWidget(_testApp(harness));
    await tester.pump();

    expect(harness.calls, hasLength(1));
    expect(harness.calls.single.pageSize, 15);
    harness.complete(
      0,
      _page([_story('initial', 'Initial story')], hasMore: false),
    );
    await _flush(tester);

    final appBarRefresh = find.widgetWithIcon(IconButton, Icons.refresh);
    final refreshButton = tester.widget<IconButton>(appBarRefresh);
    refreshButton.onPressed!();
    refreshButton.onPressed!();
    refreshButton.onPressed!();
    await tester.pump();

    expect(harness.calls, hasLength(2));
    expect(tester.widget<IconButton>(appBarRefresh).onPressed, isNull);
    harness.complete(
      1,
      _page([_story('refreshed', 'Refreshed story')], hasMore: false),
    );
    await _flush(tester);

    expect(find.text('Refreshed story'), findsOneWidget);
    expect(find.text('Initial story'), findsNothing);
    expect(find.text('Đã làm mới danh sách truyện!'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh discards an in-flight load-more response', (
    tester,
  ) async {
    final harness = _DriveLoaderHarness();
    await tester.pumpWidget(_testApp(harness));
    await tester.pump();

    harness.complete(
      0,
      _page(
        List.generate(
          24,
          (index) => _story('initial-$index', 'Initial $index'),
        ),
        nextPageToken: 'next-page',
        hasMore: true,
      ),
    );
    await _flush(tester);

    for (var attempt = 0; attempt < 5 && harness.calls.length < 2; attempt++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
      await tester.pump();
    }

    expect(harness.calls, hasLength(2));
    expect(harness.calls[1].pageSize, 15);
    expect(harness.calls[1].pageToken, 'next-page');

    await tester.tap(find.byTooltip('Làm mới Drive').first);
    await tester.pump();
    expect(harness.calls, hasLength(3));
    expect(harness.calls[2].pageToken, isNull);

    harness.complete(
      2,
      _page([_story('refreshed', 'Refreshed story')], hasMore: false),
    );
    await _flush(tester);
    harness.complete(
      1,
      _page([_story('stale-more', 'Stale next page')], hasMore: false),
    );
    await _flush(tester);

    expect(find.text('Refreshed story'), findsOneWidget);
    expect(find.text('Stale next page'), findsNothing);
    expect(find.text('Initial 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'indexed search finds an item outside the lazy page without loading Drive',
    (tester) async {
      final driveHarness = _DriveLoaderHarness();
      final searchHarness = _DriveSearchHarness(
        state: const DriveSearchIndexState(
          status: SearchIndexStatus.ready,
          indexedCount: 500,
          totalCount: 500,
          completedSources: 1,
          totalSources: 1,
        ),
        searchHandler:
            ({
              required query,
              required authors,
              required genres,
              required limit,
              required offset,
            }) async {
              return SearchIndexPage(
                items: [
                  if (offset == 0) _indexedStory('story-400', 'Kho Báu Bí Mật'),
                ],
                limit: limit,
                offset: offset,
                hasMore: false,
              );
            },
      );
      await tester.pumpWidget(
        _testApp(driveHarness, searchGateway: searchHarness),
      );
      await tester.pump();

      driveHarness.complete(
        0,
        _page([_story('story-1', 'Trang đầu')], hasMore: true),
      );
      await _flush(tester);

      await tester.tap(find.widgetWithIcon(IconButton, Icons.search));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'kho bau');
      await tester.pump(const Duration(milliseconds: 350));
      await _flush(tester);

      expect(searchHarness.searchCalls, hasLength(1));
      expect(searchHarness.searchCalls.single.query, 'kho bau');
      expect(searchHarness.searchCalls.single.offset, 0);
      expect(find.text('Kho Báu Bí Mật'), findsOneWidget);
      expect(find.text('Trang đầu'), findsNothing);
      expect(driveHarness.calls, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'metadata revisions refresh active SQL results without Drive paging',
    (tester) async {
      final driveHarness = _DriveLoaderHarness();
      var title = 'Indexed before';
      final searchHarness = _DriveSearchHarness(
        searchHandler:
            ({
              required query,
              required authors,
              required genres,
              required limit,
              required offset,
            }) async => SearchIndexPage(
              items: [_indexedStory('same', title)],
              limit: limit,
              offset: offset,
              hasMore: false,
            ),
      );
      DriveSearchIndexState state(int revision) => DriveSearchIndexState(
        status: SearchIndexStatus.indexing,
        indexedCount: 1,
        totalCount: 10,
        completedSources: 0,
        totalSources: 1,
        dataRevision: revision,
      );
      searchHarness.publish(state(0));
      await tester.pumpWidget(
        _testApp(driveHarness, searchGateway: searchHarness),
      );
      await tester.pump();
      driveHarness.complete(0, _page([_story('lazy', 'Lazy')], hasMore: false));
      await _flush(tester);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.search));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'indexed');
      await tester.pump(const Duration(milliseconds: 350));
      await _flush(tester);
      expect(find.text('Indexed before'), findsOneWidget);
      title = 'Indexed after';
      searchHarness.publish(state(1));
      searchHarness.publish(state(2));
      await tester.pump(const Duration(milliseconds: 250));
      await _flush(tester);
      expect(searchHarness.searchCalls, hasLength(2));
      expect(find.text('Indexed after'), findsOneWidget);
      expect(find.text('Indexed before'), findsNothing);
      expect(driveHarness.calls, hasLength(1));
      expect(driveHarness.calls.single.pageSize, 15);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'index retry explicitly retries failed metadata, startup does not',
    (tester) async {
      final driveHarness = _DriveLoaderHarness();
      final searchHarness = _DriveSearchHarness(
        state: const DriveSearchIndexState(
          status: SearchIndexStatus.partial,
          indexedCount: 1,
          totalCount: 1,
          completedSources: 1,
          totalSources: 1,
        ),
      );
      await tester.pumpWidget(
        _testApp(driveHarness, searchGateway: searchHarness),
      );
      await tester.pump();
      driveHarness.complete(0, _page([_story('one', 'One')], hasMore: false));
      await _flush(tester);
      expect(searchHarness.syncCalls.single.retryFailedExtractions, isFalse);
      await tester.ensureVisible(
        find.byKey(const ValueKey('drive-index-retry')),
      );
      await tester.tap(find.byKey(const ValueKey('drive-index-retry')));
      await _flush(tester);
      expect(searchHarness.syncCalls.last, (
        force: true,
        retryFailedExtractions: true,
      ));
      searchHarness.publish(
        const DriveSearchIndexState(
          status: SearchIndexStatus.indexing,
          indexedCount: 1,
          totalCount: 1,
          completedSources: 0,
          totalSources: 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('drive-index-retry')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('active indexed search paginates without Drive load-more', (
    tester,
  ) async {
    final driveHarness = _DriveLoaderHarness();
    final searchHarness = _DriveSearchHarness(
      state: const DriveSearchIndexState(
        status: SearchIndexStatus.partial,
        indexedCount: 31,
        totalCount: 500,
        completedSources: 1,
        totalSources: 2,
      ),
      searchHandler:
          ({
            required query,
            required authors,
            required genres,
            required limit,
            required offset,
          }) async {
            final count = offset == 0 ? 30 : 1;
            return SearchIndexPage(
              items: List.generate(
                count,
                (index) => _indexedStory(
                  'indexed-${offset + index}',
                  'Indexed ${offset + index}',
                ),
              ),
              limit: limit,
              offset: offset,
              hasMore: offset == 0,
            );
          },
    );
    await tester.pumpWidget(
      _testApp(driveHarness, searchGateway: searchHarness),
    );
    await tester.pump();

    driveHarness.complete(
      0,
      _page(
        List.generate(24, (index) => _story('lazy-$index', 'Lazy $index')),
        nextPageToken: 'drive-next',
        hasMore: true,
      ),
    );
    await _flush(tester);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.search));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'indexed');
    await tester.pump(const Duration(milliseconds: 350));
    await _flush(tester);
    expect(find.textContaining('Chỉ mục chưa hoàn tất'), findsOneWidget);

    for (
      var attempt = 0;
      attempt < 5 && searchHarness.searchCalls.length < 2;
      attempt++
    ) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1600));
      await _flush(tester);
    }

    expect(searchHarness.searchCalls.map((call) => call.offset), [0, 30]);
    expect(driveHarness.calls, hasLength(1));
    expect(find.text('Lazy 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('author and genre filters are forwarded to indexed search', (
    tester,
  ) async {
    final driveHarness = _DriveLoaderHarness();
    final searchHarness = _DriveSearchHarness(
      state: const DriveSearchIndexState(
        status: SearchIndexStatus.ready,
        indexedCount: 10,
        totalCount: 10,
        completedSources: 1,
        totalSources: 1,
      ),
      authors: const ['Nguyễn Nhật Ánh'],
      genres: const ['Thiếu nhi'],
    );
    await tester.pumpWidget(
      _testApp(driveHarness, searchGateway: searchHarness),
    );
    await tester.pump();
    driveHarness.complete(
      0,
      _page([_story('lazy', 'Lazy story')], hasMore: false),
    );
    await _flush(tester);

    await tester.tap(find.byKey(const ValueKey('drive-author-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nguyễn Nhật Ánh').last);
    await _flush(tester);

    expect(searchHarness.searchCalls.last.authors, ['Nguyễn Nhật Ánh']);
    expect(searchHarness.searchCalls.last.genres, isEmpty);

    await tester.tap(find.text('Thiếu nhi'));
    await _flush(tester);

    expect(searchHarness.searchCalls.last.authors, ['Nguyễn Nhật Ánh']);
    expect(searchHarness.searchCalls.last.genres, ['Thiếu nhi']);
    expect(driveHarness.calls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('index and filter controls fit a narrow large-text viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final driveHarness = _DriveLoaderHarness();
    final searchHarness = _DriveSearchHarness(
      state: const DriveSearchIndexState(
        status: SearchIndexStatus.partial,
        indexedCount: 120,
        totalCount: 500,
        completedSources: 2,
        totalSources: 6,
      ),
      authors: const ['Một tên tác giả rất dài để kiểm tra bố cục'],
      genres: const ['Khoa học viễn tưởng', 'Phiêu lưu'],
    );

    await tester.pumpWidget(
      _testApp(
        driveHarness,
        searchGateway: searchHarness,
        textScaler: const TextScaler.linear(1.5),
      ),
    );
    await tester.pump();
    driveHarness.complete(
      0,
      _page([_story('narrow', 'Narrow story')], hasMore: false),
    );
    await _flush(tester);

    expect(find.byKey(const ValueKey('drive-index-status')), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: 'The initial narrow Explore layout must not overflow.',
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await _flush(tester);
    expect(find.byKey(const ValueKey('drive-author-filter')), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: 'The narrow filter controls must not overflow after scrolling.',
    );
  });
  testWidgets('Explore opens unified search with its query and Drive gateway', (
    tester,
  ) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final driveHarness = _DriveLoaderHarness();
    final searchHarness = _DriveSearchHarness();
    await tester.pumpWidget(
      _testApp(driveHarness, searchGateway: searchHarness),
    );
    await tester.pump();
    driveHarness.complete(
      0,
      _page([_story('initial', 'Initial story')], hasMore: false),
    );
    await _flush(tester);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.search));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'book');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byTooltip('Tìm nhiều nguồn'));
    await tester.pumpAndSettle();
    final screen = tester.widget<UnifiedSearchScreen>(
      find.byType(UnifiedSearchScreen),
    );
    expect(screen.initialQuery, 'book');
    expect(identical(screen.driveSearchGateway, searchHarness), isTrue);
    expect(searchHarness.searchCalls.last.query, 'book');
    expect(driveHarness.calls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 360.0, 393.0, 412.0]) {
    for (final scale in [1.0, 1.45, 1.5]) {
      testWidgets('installed source cards fit $width px at text scale $scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final harness = _DriveLoaderHarness();
        await tester.pumpWidget(
          _testApp(
            harness,
            textScaler: TextScaler.linear(scale),
            plugins: [
              PluginInfo(
                id: 'layout-source',
                name: 'A long installed novel source name',
                version: 1234567890,
                author: '',
                description: '',
                iconUrl: '',
                downloadUrl: '',
                locale: 'vi',
                source: '',
                type: 'novel',
              ),
            ],
          ),
        );
        await tester.pump();
        harness.complete(0, _page([_story('layout', 'Book')], hasMore: false));
        await _flush(tester);
        await tester.ensureVisible(
          find.text('A long installed novel source name'),
        );
        await _flush(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('v1234567890'), findsOneWidget);
        final card = find
            .ancestor(
              of: find.text('A long installed novel source name'),
              matching: find.byType(InkWell),
            )
            .first;
        expect(tester.getSize(card).height, greaterThanOrEqualTo(68));
        expect(tester.widget<InkWell>(card).onTap, isNotNull);
      });
    }
  }
}

Widget _testApp(
  _DriveLoaderHarness harness, {
  DriveSearchGateway? searchGateway,
  TextScaler textScaler = TextScaler.noScaling,
  List<PluginInfo> plugins = const [],
}) {
  return ChangeNotifierProvider(
    create: (_) => UserProvider(adminClaimReader: _SignedOutClaimReader()),
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: ExploreScreen(
        drivePageLoader: harness.load,
        installedPluginsLoader: () async => plugins,
        driveSearchGateway: searchGateway ?? _DriveSearchHarness(),
        driveFolderInputsLoader: () async => const ['drive-root'],
      ),
    ),
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

DrivePage<Story> _page(
  List<Story> stories, {
  String? nextPageToken,
  required bool hasMore,
}) {
  return DrivePage(
    items: stories,
    nextPageToken: nextPageToken,
    hasMore: hasMore,
  );
}

Story _story(String id, String title) {
  return Story(
    id: id,
    title: title,
    driveFileId: id,
    isFromDrive: true,
    fileType: 'pdf',
  );
}

SearchIndexStory _indexedStory(String id, String title) {
  return SearchIndexStory(
    sourceType: 'googleDrive',
    sourceId: 'drive-root',
    remoteId: id,
    driveFileId: id,
    title: title,
    mimeType: 'application/pdf',
    metadataStatus: SearchMetadataStatus.complete,
    lastIndexedAt: DateTime.utc(2026, 9, 4),
  );
}

class _DriveLoaderHarness {
  final calls = <_DriveCall>[];

  Future<DrivePage<Story>> load({required int pageSize, String? pageToken}) {
    final call = _DriveCall(pageSize: pageSize, pageToken: pageToken);
    calls.add(call);
    return call.completer.future;
  }

  void complete(int index, DrivePage<Story> page) {
    calls[index].completer.complete(page);
  }
}

class _DriveCall {
  final int pageSize;
  final String? pageToken;
  final Completer<DrivePage<Story>> completer = Completer<DrivePage<Story>>();

  _DriveCall({required this.pageSize, required this.pageToken});
}

typedef _SearchHandler =
    Future<SearchIndexPage> Function({
      required String query,
      required List<String> authors,
      required List<String> genres,
      required int limit,
      required int offset,
    });

class _DriveSearchHarness extends ChangeNotifier implements DriveSearchGateway {
  _DriveSearchHarness({
    DriveSearchIndexState state = const DriveSearchIndexState.notStarted(),
    _SearchHandler? searchHandler,
    this.authors = const [],
    this.genres = const [],
  }) : _state = state,
       _searchHandler = searchHandler;

  DriveSearchIndexState _state;
  final _SearchHandler? _searchHandler;
  final List<String> authors;
  final List<String> genres;
  final List<_SearchCall> searchCalls = [];
  final syncCalls = <({bool force, bool retryFailedExtractions})>[];

  @override
  DriveSearchIndexState get state => _state;

  void publish(DriveSearchIndexState state) {
    _state = state;
    notifyListeners();
  }

  @override
  Future<List<String>> loadAuthors() async => authors;

  @override
  Future<List<String>> loadGenres() async => genres;

  @override
  Future<void> restoreState(Iterable<String> folderInputs) async {}

  @override
  Future<SearchIndexPage> search({
    String query = '',
    Iterable<String> authors = const [],
    Iterable<String> genres = const [],
    int limit = 20,
    int offset = 0,
  }) {
    final call = _SearchCall(
      query: query,
      authors: authors.toList(growable: false),
      genres: genres.toList(growable: false),
      limit: limit,
      offset: offset,
    );
    searchCalls.add(call);
    final handler = _searchHandler;
    if (handler != null) {
      return handler(
        query: call.query,
        authors: call.authors,
        genres: call.genres,
        limit: call.limit,
        offset: call.offset,
      );
    }
    return Future.value(
      SearchIndexPage(
        items: const [],
        limit: limit,
        offset: offset,
        hasMore: false,
      ),
    );
  }

  @override
  Future<void> synchronize(
    Iterable<String> folderInputs, {
    bool force = false,
    bool retryFailedExtractions = false,
  }) async {
    syncCalls.add((
      force: force,
      retryFailedExtractions: retryFailedExtractions,
    ));
  }
}

class _SearchCall {
  const _SearchCall({
    required this.query,
    required this.authors,
    required this.genres,
    required this.limit,
    required this.offset,
  });

  final String query;
  final List<String> authors;
  final List<String> genres;
  final int limit;
  final int offset;
}

class _SignedOutClaimReader implements AdminClaimReader {
  @override
  String? get currentUserId => null;

  @override
  Stream<String?> get userIdChanges => const Stream<String?>.empty();

  @override
  Future<Map<String, dynamic>?> readClaims({required bool forceRefresh}) async {
    return null;
  }
}
