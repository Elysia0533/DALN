import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/search_capabilities.dart';
import 'package:online_story_reader/models/story.dart';
import 'package:online_story_reader/models/unified_search.dart';
import 'package:online_story_reader/services/search/unified_search_controller.dart';
import 'package:online_story_reader/services/search/unified_search_gateway.dart';

void main() {
  final drive = AppUnifiedSearchGateway.driveSource;
  final local = AppUnifiedSearchGateway.localSource;
  final extension = SearchSource(
    type: SearchSourceType.extension,
    id: 'test',
    name: 'Extension',
    capabilities: SearchCapabilities(
      supportsKeyword: true,
      supportsPagination: true,
    ),
  );
  late _Gateway gateway;
  late UnifiedSearchController controller;
  setUp(() {
    gateway = _Gateway();
    controller = UnifiedSearchController(gateway);
  });
  tearDown(() => controller.dispose());

  test(
    'only selected sources run; fast results survive a slow source error',
    () async {
      final pending = Completer<SourceSearchPage>();
      gateway.execute = (source, _, _) => source.key == drive.key
          ? Future.value(_page(source, 'same-id'))
          : pending.future;
      final search = controller.search([
        drive,
        extension,
      ], const UnifiedSearchQuery(text: 'book'));
      await Future<void>.delayed(Duration.zero);
      expect(gateway.called, [drive.key, extension.key]);
      expect(controller.states.first.items.single.remoteId, 'same-id');
      expect(controller.states.last.status, SourceSearchStatus.loading);
      pending.completeError(TimeoutException('private upstream details'));
      await search;
      expect(controller.states.first.status, SourceSearchStatus.ready);
      expect(controller.states.last.status, SourceSearchStatus.error);
      expect(controller.states.last.message, contains('quá lâu'));
      expect(controller.states.last.message, isNot(contains('private')));
    },
  );

  test(
    'old responses cannot overwrite a changed query or cleared state',
    () async {
      final pending = Completer<SourceSearchPage>();
      gateway.execute = (source, query, _) => query.text == 'old'
          ? pending.future
          : Future.value(_page(source, 'new'));
      final old = controller.search([
        drive,
      ], const UnifiedSearchQuery(text: 'old'));
      await controller.search([drive], const UnifiedSearchQuery(text: 'new'));
      pending.complete(_page(drive, 'old'));
      await old;
      expect(controller.states.single.items.single.remoteId, 'new');
      final cleared = Completer<SourceSearchPage>();
      gateway.execute = (_, _, _) => cleared.future;
      final search = controller.search([
        local,
      ], const UnifiedSearchQuery(text: 'book'));
      controller.clear();
      cleared.complete(_page(local, 'late'));
      await search;
      expect(controller.states, isEmpty);
    },
  );

  test(
    'unsupported filters fail per source without calling its executor',
    () async {
      await controller.search([
        drive,
        extension,
      ], const UnifiedSearchQuery(text: 'book', author: 'Author'));
      expect(gateway.called, [drive.key]);
      expect(controller.states.last.status, SourceSearchStatus.unsupported);
    },
  );

  test('same title and remote id remain distinct across sources', () async {
    gateway.execute = (source, _, _) async => _page(source, 'shared');
    await controller.search([
      drive,
      local,
      extension,
    ], const UnifiedSearchQuery(text: 'book'));
    final results = controller.states.expand((s) => s.items).toList();
    expect(results, hasLength(3));
    expect(results.map((r) => r.stableId).toSet(), hasLength(3));
  });

  test(
    'pagination preserves previous results on failure and retries the same page',
    () async {
      var fail = true;
      final pages = <int>[];
      gateway.execute = (source, _, page) async {
        pages.add(page);
        if (page == 2 && fail) throw StateError('upstream');
        return page == 1
            ? _page(source, 'one', nextPage: 2)
            : SourceSearchPage(
                items: [
                  ..._page(source, 'one').items,
                  ..._page(source, 'two').items,
                ],
                nextPage: 3,
              );
      };
      await controller.search([
        extension,
      ], const UnifiedSearchQuery(text: 'book'));
      await controller.loadMore(extension.key);
      expect(controller.states.single.items, hasLength(1));
      expect(controller.states.single.failedPage, 2);
      fail = false;
      await controller.retry(extension.key);
      expect(pages, [1, 2, 2]);
      expect(controller.states.single.items.map((r) => r.remoteId), [
        'one',
        'two',
      ]);
      await controller.loadMore(extension.key);
      expect(controller.states.single.nextPage, isNull);
      expect(controller.states.single.items, hasLength(2));
    },
  );

  test('non-paginated source suppresses a spurious next page', () async {
    final source = SearchSource(
      type: SearchSourceType.extension,
      id: 'single',
      name: 'Single',
      capabilities: SearchCapabilities(supportsKeyword: true),
    );
    gateway.execute = (source, _, _) async => _page(source, 'one', nextPage: 2);
    await controller.search([source], const UnifiedSearchQuery(text: 'book'));
    expect(controller.states.single.nextPage, isNull);
    await controller.loadMore(source.key);
    expect(gateway.called, hasLength(1));
  });

  test(
    'empty input never searches or lists the entire remote catalog',
    () async {
      await controller.search([
        drive,
        extension,
      ], const UnifiedSearchQuery(text: '  '));
      expect(gateway.called, isEmpty);
    },
  );

  test('a response after dispose cannot notify listeners', () async {
    final pending = Completer<SourceSearchPage>();
    gateway.execute = (_, _, _) => pending.future;
    final disposed = UnifiedSearchController(gateway);
    var notifications = 0;
    disposed.addListener(() => notifications++);
    final search = disposed.search([
      drive,
    ], const UnifiedSearchQuery(text: 'book'));
    disposed.dispose();
    final before = notifications;
    pending.complete(_page(drive, 'late'));
    await search;
    expect(notifications, before);
  });

  test(
    'refresh replaces one source while preserving results during loading',
    () async {
      await controller.search([
        drive,
        extension,
      ], const UnifiedSearchQuery(text: 'book'));
      final pending = Completer<SourceSearchPage>();
      gateway.execute = (_, _, _) => pending.future;
      final refresh = controller.refreshSource(drive.key);
      expect(controller.states.first.items.single.remoteId, 'default');
      expect(controller.states.last.status, SourceSearchStatus.ready);
      pending.complete(_page(drive, 'updated', nextPage: 2));
      await refresh;
      expect(controller.states.first.items.single.remoteId, 'updated');
      expect(controller.states.first.nextPage, 2);
      expect(gateway.called, [drive.key, extension.key, drive.key]);
    },
  );

  test('late pagination cannot append to a newer index refresh', () async {
    gateway.execute = (source, _, _) async => _page(source, 'one', nextPage: 2);
    await controller.search([drive], const UnifiedSearchQuery(text: 'book'));
    final pending = Completer<SourceSearchPage>();
    gateway.execute = (source, _, page) =>
        page == 2 ? pending.future : Future.value(_page(source, 'replacement'));
    final more = controller.loadMore(drive.key);
    await controller.refreshSource(drive.key);
    pending.complete(_page(drive, 'obsolete', nextPage: 3));
    await more;
    expect(controller.states.single.items.single.remoteId, 'replacement');
    expect(controller.states.single.nextPage, isNull);
  });

  test(
    'refresh failures keep results and later requests win in the same query',
    () async {
      await controller.search([drive], const UnifiedSearchQuery(text: 'book'));
      gateway.execute = (_, _, _) async => throw StateError('read failed');
      await controller.refreshSource(drive.key);
      expect(controller.states.single.status, SourceSearchStatus.error);
      expect(controller.states.single.items.single.remoteId, 'default');
      final pending = Completer<SourceSearchPage>();
      gateway.execute = (_, _, _) => pending.future;
      final older = controller.refreshSource(drive.key);
      gateway.execute = (source, _, _) async => _page(source, 'latest');
      await controller.refreshSource(drive.key);
      pending.complete(_page(drive, 'obsolete'));
      await older;
      expect(controller.states.single.items.single.remoteId, 'latest');
      controller.clear();
      final count = gateway.called.length;
      await controller.refreshSource(drive.key);
      expect(gateway.called, hasLength(count));
    },
  );
}

SourceSearchPage _page(SearchSource source, String id, {int? nextPage}) =>
    SourceSearchPage(
      items: [
        SearchResult(
          source: source,
          remoteId: id,
          story: Story(id: id, title: 'Same title'),
        ),
      ],
      nextPage: nextPage,
    );

class _Gateway implements UnifiedSearchGateway {
  final called = <String>[];
  Future<SourceSearchPage> Function(SearchSource, UnifiedSearchQuery, int)
  execute = (source, _, _) async => _page(source, 'default');
  @override
  Future<List<SearchSource>> loadSources() async => [];
  @override
  Future<SearchFacets> facets(SearchSource source) async => SearchFacets();
  @override
  Future<SourceSearchPage> search(
    SearchSource source,
    UnifiedSearchQuery query,
    int page, {
    required bool Function() isCurrent,
  }) {
    called.add(source.key);
    return execute(source, query, page);
  }
}
