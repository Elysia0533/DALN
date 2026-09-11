import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/models/search_capabilities.dart';

void main() {
  group('SearchCapabilities', () {
    test('legacy search script enables keyword and page search only', () {
      final plugin = PluginInfo.fromRegistryJson(<String, dynamic>{
        'metadata': <String, dynamic>{'name': 'Legacy source'},
        'script': <String, dynamic>{'search': 'search.js', 'genre': 'genre.js'},
      });

      expect(plugin.searchCapabilities.supportsKeyword, isTrue);
      expect(plugin.searchCapabilities.supportsPagination, isTrue);
      expect(plugin.searchCapabilities.supportsAuthor, isFalse);
      expect(plugin.searchCapabilities.supportsGenre, isFalse);
      expect(plugin.searchCapabilities.availableGenres, isEmpty);
    });

    test('genre listing script alone is not treated as genre search', () {
      final plugin = PluginInfo.fromRegistryJson(<String, dynamic>{
        'metadata': <String, dynamic>{'name': 'Browse-only source'},
        'script': <String, dynamic>{'genre': 'genre.js'},
      });

      expect(plugin.searchCapabilities, SearchCapabilities.none);
    });

    test('versioned declaration exposes only supported source filters', () {
      final plugin = PluginInfo.fromRegistryJson(<String, dynamic>{
        'metadata': <String, dynamic>{'name': 'Declared source'},
        'script': <String, dynamic>{'search': 'search.js'},
        'searchCapabilities': <String, dynamic>{
          'version': 2,
          'supportsKeyword': false,
          'supportsAuthor': true,
          'supportsGenre': true,
          'supportsPagination': false,
          'availableGenres': <Object?>[
            ' Fantasy ',
            'fantasy',
            'Khoa   học',
            '',
            42,
          ],
        },
      });

      final capabilities = plugin.searchCapabilities;
      expect(capabilities.version, 2);
      expect(capabilities.supportsKeyword, isFalse);
      expect(capabilities.supportsAuthor, isTrue);
      expect(capabilities.supportsGenre, isTrue);
      expect(capabilities.supportsPagination, isFalse);
      expect(capabilities.availableGenres, <String>['Fantasy', 'Khoa học']);
    });

    test('declaration cannot advertise search without a search script', () {
      final plugin = PluginInfo.fromRegistryJson(<String, dynamic>{
        'metadata': <String, dynamic>{'name': 'Invalid source'},
        'script': <String, dynamic>{'genre': 'genre.js'},
        'capabilities': <String, dynamic>{
          'search': <String, dynamic>{
            'supportsKeyword': true,
            'supportsAuthor': true,
            'supportsGenre': true,
            'supportsPagination': true,
            'availableGenres': <String>['Fantasy'],
          },
        },
      });

      expect(plugin.searchCapabilities, SearchCapabilities.none);
    });

    test('stored capability data round-trips with installed plugin data', () {
      final original = _plugin(
        scripts: const <String, String>{'search': 'search.js'},
        searchCapabilities: SearchCapabilities(
          version: 1,
          supportsKeyword: true,
          supportsGenre: true,
          supportsPagination: false,
          availableGenres: const <String>['Tiên hiệp', 'Kỳ ảo'],
        ),
      );

      final restored = PluginInfo.fromJson(original.toJson());

      expect(restored.scripts, original.scripts);
      expect(restored.searchCapabilities, original.searchCapabilities);
    });

    test('malformed stored declaration falls back without crashing', () {
      final restored = PluginInfo.fromJson(<String, dynamic>{
        ..._plugin().toJson(),
        'scripts': <String, Object?>{'search': 'search.js', 'bad': null},
        'searchCapabilities': 'not-an-object',
      });

      expect(restored.scripts, <String, String>{'search': 'search.js'});
      expect(restored.searchCapabilities.supportsKeyword, isTrue);
      expect(restored.searchCapabilities.supportsPagination, isTrue);
      expect(restored.searchCapabilities.supportsGenre, isFalse);
    });
  });
}

PluginInfo _plugin({
  Map<String, String> scripts = const <String, String>{},
  SearchCapabilities? searchCapabilities,
}) {
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
    scripts: scripts,
    searchCapabilities: searchCapabilities,
    isInstalled: true,
    installedVersion: 1,
  );
}
