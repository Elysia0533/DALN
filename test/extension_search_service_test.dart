import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/models/search_capabilities.dart';
import 'package:online_story_reader/models/source_models.dart';
import 'package:online_story_reader/services/search/extension_search_service.dart';

void main() {
  test(
    'keyword search uses the extension executor with a trimmed query',
    () async {
      String? calledSourceId;
      String? calledQuery;
      int? calledPage;
      final service = ExtensionSearchService(
        keywordExecutor: (sourceId, query, page) async {
          calledSourceId = sourceId;
          calledQuery = query;
          calledPage = page;
          return MangasPage(<SManga>[_manga('Result')], true);
        },
      );

      final result = await service.searchKeyword(
        plugin: _plugin(
          SearchCapabilities(supportsKeyword: true, supportsPagination: true),
        ),
        query: '  tên truyện  ',
        page: 2,
      );

      expect(calledSourceId, 'source.test');
      expect(calledQuery, 'tên truyện');
      expect(calledPage, 2);
      expect(result.mangas.single.title, 'Result');
      expect(result.hasNextPage, isTrue);
    },
  );

  test('unsupported keyword search never invokes the extension', () async {
    var callCount = 0;
    final service = ExtensionSearchService(
      keywordExecutor: (_, _, _) async {
        callCount++;
        return MangasPage(<SManga>[], false);
      },
    );

    await expectLater(
      service.searchKeyword(
        plugin: _plugin(SearchCapabilities.none),
        query: 'query',
      ),
      throwsA(
        isA<ExtensionSearchCapabilityException>().having(
          (error) => error.code,
          'code',
          'KEYWORD_UNSUPPORTED',
        ),
      ),
    );
    expect(callCount, 0);
  });

  test('non-paginated source cannot request a second page', () async {
    var callCount = 0;
    final service = ExtensionSearchService(
      keywordExecutor: (_, _, _) async {
        callCount++;
        return MangasPage(<SManga>[], false);
      },
    );
    final plugin = _plugin(
      SearchCapabilities(supportsKeyword: true, supportsPagination: false),
    );

    await expectLater(
      service.searchKeyword(plugin: plugin, query: 'query', page: 2),
      throwsA(
        isA<ExtensionSearchCapabilityException>().having(
          (error) => error.code,
          'code',
          'PAGINATION_UNSUPPORTED',
        ),
      ),
    );
    expect(callCount, 0);
  });

  test('non-paginated source cannot expose a native next page', () async {
    final service = ExtensionSearchService(
      keywordExecutor: (_, _, _) async =>
          MangasPage(<SManga>[_manga('Only page')], true),
    );

    final result = await service.searchKeyword(
      plugin: _plugin(
        SearchCapabilities(supportsKeyword: true, supportsPagination: false),
      ),
      query: 'query',
    );

    expect(result.mangas, hasLength(1));
    expect(result.hasNextPage, isFalse);
  });

  test('null engine response is an explicit invalid-response error', () async {
    final service = ExtensionSearchService(
      keywordExecutor: (_, _, _) async => null,
    );

    await expectLater(
      service.searchKeyword(
        plugin: _plugin(
          SearchCapabilities(supportsKeyword: true, supportsPagination: true),
        ),
        query: 'query',
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          'The extension engine returned an invalid response.',
        ),
      ),
    );
  });
}

PluginInfo _plugin(SearchCapabilities capabilities) {
  return PluginInfo(
    id: 'source.test',
    name: 'Source',
    author: 'Author',
    source: 'https://example.com',
    iconUrl: '',
    description: '',
    type: 'novel',
    locale: 'vi',
    version: 1,
    downloadUrl: 'https://example.com/plugin.zip',
    scripts: const <String, String>{'search': 'search.js'},
    searchCapabilities: capabilities,
  );
}

SManga _manga(String title) {
  final manga = SManga.create();
  manga.title = title;
  return manga;
}
