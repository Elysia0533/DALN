import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/search_capabilities.dart';
import 'package:online_story_reader/models/search_index_page.dart';
import 'package:online_story_reader/models/search_index_state.dart';
import 'package:online_story_reader/models/story.dart';
import 'package:online_story_reader/models/unified_search.dart';
import 'package:online_story_reader/screens/unified_search_screen.dart';
import 'package:online_story_reader/services/search/drive_search_coordinator.dart';
import 'package:online_story_reader/services/search/unified_search_gateway.dart';

void main() {
  late _Drive drive;
  setUp(() => drive = _Drive());
  tearDown(() => drive.dispose());
  for (final size in [
    const Size(320, 640),
    const Size(360, 720),
    const Size(393, 800),
    const Size(412, 800),
    const Size(640, 320),
  ]) {
    for (final scale in [1.0, 1.3, 1.5]) {
      testWidgets('search and source selector fit $size text=$scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final gateway = _Gateway();
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: UnifiedSearchScreen(
              gateway: gateway,
              driveSearchGateway: drive,
              initialQuery: 'book',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('unified-sources')));
        await tester.pumpAndSettle();
        expect(find.text('Tất cả nguồn'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Tất cả nguồn'));
        await tester.tap(find.text('Áp dụng'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(gateway.calls.map((c) => c.source.key).toSet(), hasLength(3));
        final filters = tester.widgetList<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        );
        expect(filters, hasLength(2));
        expect(filters.every((f) => f.onChanged == null), isTrue);
        await tester.drag(
          find.byKey(const ValueKey('unified-scroll')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('source error leaves Drive result tappable and retryable', (
    tester,
  ) async {
    final gateway = _Gateway()..failExtension = true;
    SearchResult? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedSearchScreen(
          gateway: gateway,
          driveSearchGateway: drive,
          initialQuery: 'book',
          onOpenResult: (result) => opened = result,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('unified-sources')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tất cả nguồn'));
    await tester.tap(find.text('Áp dụng'));
    await tester.pumpAndSettle();
    final result = gateway.result(AppUnifiedSearchGateway.driveSource);
    await tester.ensureVisible(find.byKey(ValueKey(result.stableId)));
    await tester.tap(find.byKey(ValueKey(result.stableId)));
    expect(opened?.source.type, SearchSourceType.drive);
    await tester.scrollUntilVisible(
      find.text('Thử lại'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    gateway.failExtension = false;
    await tester.tap(find.text('Thử lại'));
    await tester.pumpAndSettle();
    expect(find.text('Thử lại'), findsNothing);
    expect(
      gateway.calls.where((c) => c.source.type == SearchSourceType.extension),
      hasLength(2),
    );
  });

  testWidgets(
    'cancel source picker does not issue searches; explicit submit uses new text',
    (tester) async {
      final gateway = _Gateway();
      await tester.pumpWidget(
        MaterialApp(
          home: UnifiedSearchScreen(
            gateway: gateway,
            driveSearchGateway: drive,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(gateway.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('unified-sources')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tất cả nguồn'));
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(gateway.calls, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('unified-query')),
        'new query',
      );
      await tester.tap(find.byKey(const ValueKey('unified-submit')));
      await tester.pumpAndSettle();
      expect(gateway.calls.single.query.text, 'new query');
      expect(gateway.calls.single.source.type, SearchSourceType.drive);
      await tester.enterText(
        find.byKey(const ValueKey('unified-query')),
        'changed',
      );
      await tester.pump();
      expect(find.byType(ListTile), findsNothing);
    },
  );

  testWidgets('index commits refresh Drive only and coalesce bursts', (
    tester,
  ) async {
    final gateway = _Gateway();
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedSearchScreen(
          gateway: gateway,
          driveSearchGateway: drive,
          initialQuery: 'book',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('unified-sources')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tất cả nguồn'));
    await tester.tap(find.text('Áp dụng'));
    await tester.pumpAndSettle();
    gateway.calls.clear();
    gateway.driveTitle = 'Newly indexed title';
    for (var revision = 1; revision <= 3; revision++) {
      drive.publish(revision);
    }
    await tester.pump(const Duration(milliseconds: 249));
    expect(gateway.calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(gateway.calls.single.source.type, SearchSourceType.drive);
    expect(find.text('Newly indexed title'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // A metadata-only change must refresh even when the row count is unchanged.
    gateway.calls.clear();
    drive.publish(4);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(gateway.calls.single.source.type, SearchSourceType.drive);
    gateway.calls.clear();
    drive.publish(5);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(gateway.calls, isEmpty);
    expect(drive.hasActiveListeners, isFalse);
  });
}

class _Drive extends ChangeNotifier implements DriveSearchGateway {
  bool get hasActiveListeners => hasListeners;
  DriveSearchIndexState _state = const DriveSearchIndexState.notStarted();
  @override
  DriveSearchIndexState get state => _state;
  void publish(int revision) {
    _state = DriveSearchIndexState(
      status: SearchIndexStatus.indexing,
      indexedCount: 2,
      totalCount: 10,
      completedSources: 0,
      totalSources: 1,
      dataRevision: revision,
    );
    notifyListeners();
  }

  @override
  Future<void> restoreState(Iterable<String> folderInputs) async {}
  @override
  Future<void> synchronize(
    Iterable<String> folderInputs, {
    bool force = false,
    bool retryFailedExtractions = false,
  }) async {}
  @override
  Future<List<String>> loadAuthors() async => [];
  @override
  Future<List<String>> loadGenres() async => [];
  @override
  Future<SearchIndexPage> search({
    String query = '',
    Iterable<String> authors = const [],
    Iterable<String> genres = const [],
    int limit = 30,
    int offset = 0,
  }) =>
      throw UnimplementedError('The widget uses the injected unified gateway.');
}

class _Gateway implements UnifiedSearchGateway {
  final calls = <({SearchSource source, UnifiedSearchQuery query})>[];
  bool failExtension = false;
  String? driveTitle;
  final extension = SearchSource(
    type: SearchSourceType.extension,
    id: 'ext',
    name: 'Nguồn truyện có tên rất dài để kiểm tra giao diện',
    capabilities: SearchCapabilities(supportsKeyword: true),
  );
  SearchResult result(SearchSource source) => SearchResult(
    source: source,
    remoteId: 'same',
    story: Story(
      id: 'same',
      title: source.type == SearchSourceType.drive && driveTitle != null
          ? driveTitle!
          : 'Tên truyện rất dài vẫn đọc được trong danh sách kết quả',
      author: 'Tác giả có tên rất dài',
    ),
  );
  @override
  Future<List<SearchSource>> loadSources() async => [
    AppUnifiedSearchGateway.driveSource,
    AppUnifiedSearchGateway.localSource,
    extension,
  ];
  @override
  Future<SearchFacets> facets(SearchSource source) async =>
      SearchFacets(authors: ['Tác giả'], genres: ['Tiểu thuyết']);
  @override
  Future<SourceSearchPage> search(
    SearchSource source,
    UnifiedSearchQuery query,
    int page, {
    required bool Function() isCurrent,
  }) async {
    calls.add((source: source, query: query));
    if (source.type == SearchSourceType.extension && failExtension) {
      throw TimeoutException('timeout');
    }
    return SourceSearchPage(items: [result(source)]);
  }
}
