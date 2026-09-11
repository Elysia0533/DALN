import '../../models/plugin_info.dart';
import '../../models/search_capabilities.dart';
import '../../models/search_index_story.dart';
import '../../models/story.dart';
import '../../models/unified_search.dart';
import '../extension_service.dart';
import '../google_drive_service.dart';
import 'drive_search_coordinator.dart';
import 'extension_search_runner.dart';
import 'local_library_search_index.dart';

abstract interface class UnifiedSearchGateway {
  Future<List<SearchSource>> loadSources();
  Future<SearchFacets> facets(SearchSource source);
  Future<SourceSearchPage> search(
    SearchSource source,
    UnifiedSearchQuery query,
    int page, {
    required bool Function() isCurrent,
  });
}

class AppUnifiedSearchGateway implements UnifiedSearchGateway {
  AppUnifiedSearchGateway({
    required this.drive,
    LocalLibrarySearchIndex? library,
    ExtensionSearchRunner? extensions,
    Future<List<PluginInfo>> Function()? loadPlugins,
  }) : library = library ?? LocalLibrarySearchIndex.instance,
       _loadPlugins = loadPlugins ?? ExtensionService.getInstalledPlugins,
       extensions = extensions ?? ExtensionSearchRunner.instance;

  final DriveSearchGateway drive;
  final LocalLibrarySearchIndex library;
  final ExtensionSearchRunner extensions;
  final Future<List<PluginInfo>> Function() _loadPlugins;
  static const pageSize = 30;

  static final driveSource = SearchSource(
    type: SearchSourceType.drive,
    id: 'drive',
    name: 'Google Drive',
    capabilities: SearchCapabilities(
      supportsKeyword: true,
      supportsAuthor: true,
      supportsGenre: true,
      supportsPagination: true,
    ),
  );
  static final localSource = SearchSource(
    type: SearchSourceType.local,
    id: LocalLibrarySearchIndex.sourceId,
    name: 'Thư viện',
    capabilities: SearchCapabilities(
      supportsKeyword: true,
      supportsAuthor: true,
      supportsGenre: true,
      supportsPagination: true,
    ),
  );

  @override
  Future<List<SearchSource>> loadSources() async {
    final plugins = await _loadPlugins();
    return [
      driveSource,
      localSource,
      for (final plugin in plugins)
        if (plugin.type == 'novel' || plugin.type == 'chinese_novel')
          SearchSource(
            type: SearchSourceType.extension,
            id: plugin.id,
            name: plugin.name,
            plugin: plugin,
            // The current native bridge has keyword/page arguments only.
            // A manifest declaration alone cannot enable author/genre transport.
            capabilities: SearchCapabilities(
              supportsKeyword: plugin.searchCapabilities.supportsKeyword,
              supportsPagination: plugin.searchCapabilities.supportsPagination,
            ),
          ),
    ];
  }

  @override
  Future<SearchFacets> facets(SearchSource source) async {
    return switch (source.type) {
      SearchSourceType.drive => SearchFacets(
        authors: await drive.loadAuthors(),
        genres: await drive.loadGenres(),
      ),
      SearchSourceType.local => await library.facets(),
      SearchSourceType.extension => SearchFacets(),
    };
  }

  @override
  Future<SourceSearchPage> search(
    SearchSource source,
    UnifiedSearchQuery query,
    int page, {
    required bool Function() isCurrent,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    if (source.type == SearchSourceType.local) {
      return library.search(source, query, page);
    }
    if (source.type == SearchSourceType.drive) {
      final result = await drive.search(
        query: query.text,
        authors: query.author == null ? [] : [query.author!],
        genres: query.genre == null ? [] : [query.genre!],
        limit: pageSize,
        offset: (page - 1) * pageSize,
      );
      return SourceSearchPage(
        items: [
          for (final item in result.items)
            SearchResult(
              source: source,
              remoteId: item.driveFileId ?? item.remoteId,
              story: Story(
                id: item.remoteId,
                title: item.title,
                author: item.authors.join(', '),
                genres: item.genres,
                description: item.description,
                driveFileId: item.driveFileId ?? item.remoteId,
                isFromDrive: true,
                iconUrl: _cover(item),
                fileType: item.mimeType.toLowerCase().contains('epub')
                    ? 'epub'
                    : item.mimeType.toLowerCase().contains('pdf')
                    ? 'pdf'
                    : item.mimeType.toLowerCase().startsWith('text/')
                    ? 'txt'
                    : '',
              ),
            ),
        ],
        nextPage: result.hasMore ? page + 1 : null,
      );
    }
    if (query.author != null || query.genre != null) {
      throw UnsupportedError('Extension filters unavailable.');
    }
    final plugin = source.plugin!;
    final result = await extensions.search(
      plugin,
      query.text.trim(),
      page,
      isCurrent: isCurrent,
    );
    return SourceSearchPage(
      items: [
        for (final item in result.mangas)
          if (item.url.trim().isNotEmpty && item.title.trim().isNotEmpty)
            SearchResult(
              source: source,
              remoteId: item.url,
              story: Story(
                id: item.url,
                title: item.title,
                author: item.author,
                description: item.description,
                iconUrl: item.thumbnailUrl,
                genres: item.genre.trim().isEmpty
                    ? []
                    : item.genre
                          .split(',')
                          .map((s) => s.trim())
                          .where((s) => s.isNotEmpty)
                          .toList(),
                pluginId: plugin.id,
                storyUrl: item.url,
              ),
            ),
      ],
      nextPage: result.hasNextPage ? page + 1 : null,
    );
  }

  static String _cover(SearchIndexStory item) {
    for (final candidate in [item.coverLocalPath, item.coverUrl]) {
      if (candidate != null && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    final fileId = item.coverFileId?.trim() ?? '';
    return fileId.isEmpty ? '' : GoogleDriveService.getCoverImageUrl(fileId);
  }
}
