import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/search_index_state.dart';
import '../models/search_index_story.dart';
import '../models/story.dart';
import '../services/api_service.dart';
import '../services/extension_service.dart';
import '../models/plugin_info.dart';
import '../services/search/drive_search_coordinator.dart';
import '../services/search/unified_search_gateway.dart';
import 'unified_search_screen.dart';
import '../theme/user_provider.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/story_cover_image.dart';
import '../services/google_drive_service.dart';
import '../utils/app_performance_logger.dart';
import 'source_browse_screen.dart';

import 'story_detail_screen.dart';
import 'online_story_detail_screen.dart';
import 'extension_screen.dart';

class ExploreScreen extends StatefulWidget {
  final Future<DrivePage<Story>> Function({
    required int pageSize,
    String? pageToken,
  })?
  drivePageLoader;
  final Future<List<PluginInfo>> Function()? installedPluginsLoader;
  final DriveSearchGateway? driveSearchGateway;
  final Future<List<String>> Function()? driveFolderInputsLoader;

  const ExploreScreen({
    super.key,
    this.drivePageLoader,
    this.installedPluginsLoader,
    this.driveSearchGateway,
    this.driveFolderInputsLoader,
  });

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  static const int _drivePageSize = 15;
  static const int _searchPageSize = 30;
  static const Duration _searchDebounce = Duration(milliseconds: 300);

  List<Story> _serverStories = [];
  final Set<String> _seenStoryIds = {};
  String? _nextPageToken;
  bool _hasMore = true;

  bool _isLoading = true;
  bool _isLoadingMore = false;
  Object? _loadMoreError;
  bool _isSearching = false;
  bool _isEnrichingMetadata = false;
  int _driveLoadGeneration = 0;
  Future<void>? _serverStoriesLoad;
  String? _loadError;
  List<PluginInfo> _installedPlugins = [];

  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounceTimer;
  Timer? _indexRefreshTimer;
  bool _indexRefreshResults = false;
  int _searchGeneration = 0;
  List<Story> _indexedSearchStories = [];
  bool _isSearchLoading = false;
  bool _isSearchLoadingMore = false;
  bool _searchHasMore = false;
  Object? _searchError;

  late final DriveSearchGateway _driveSearchGateway;
  late DriveSearchIndexState _driveIndexState;
  Future<List<String>>? _driveFolderInputsFuture;
  int _facetLoadGeneration = 0;

  List<String> _allGenres = ['Tất cả'];
  final Set<String> _selectedGenres = {};
  List<String> _allAuthors = [];
  String? _selectedAuthor;

  @override
  void initState() {
    super.initState();
    _driveSearchGateway =
        widget.driveSearchGateway ?? DriveSearchCoordinator.instance;
    _driveIndexState = _driveSearchGateway.state;
    _driveSearchGateway.addListener(_handleDriveIndexStateChanged);
    _loadServerStories();
    unawaited(_initializeDriveSearch());
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _indexRefreshTimer?.cancel();
    _driveSearchGateway.removeListener(_handleDriveIndexStateChanged);
    _searchController.dispose();
    super.dispose();
  }

  Future<DrivePage<Story>> _fetchDrivePage({
    required int pageSize,
    String? pageToken,
  }) async {
    final loader = widget.drivePageLoader;
    if (loader != null) {
      return loader(pageSize: pageSize, pageToken: pageToken);
    }
    final folderInputs = await _resolveDriveFolderInputs();
    return GoogleDriveService.fetchStoriesPage(
      pageSize: pageSize,
      pageToken: pageToken,
      extraFolderUrls: folderInputs,
    );
  }

  Future<List<String>> _resolveDriveFolderInputs() {
    final cached = _driveFolderInputsFuture;
    if (cached != null) return cached;

    final configuredLoader = widget.driveFolderInputsLoader;
    final future = configuredLoader != null
        ? configuredLoader()
        : ApiService.getSavedDriveStoryFolderInputs().then(
            (savedInputs) => GoogleDriveService.configuredFolderInputs(
              extraFolderUrls: savedInputs,
            ),
          );
    _driveFolderInputsFuture = future;
    return future;
  }

  Future<List<PluginInfo>> _loadInstalledPlugins() {
    return widget.installedPluginsLoader?.call() ??
        ExtensionService.getInstalledPlugins();
  }

  Future<void> _initializeDriveSearch() async {
    try {
      final folderInputs = await _resolveDriveFolderInputs();
      await _driveSearchGateway.restoreState(folderInputs);
      if (mounted) {
        await _loadSearchFacets();
      }
      unawaited(_synchronizeDriveSearch());
    } catch (_) {
      _setDriveIndexFailure('index_initialization_failed');
    }
  }

  Future<void> _synchronizeDriveSearch({
    bool force = false,
    bool reloadFolderInputs = false,
    bool retryFailedExtractions = false,
  }) async {
    try {
      if (reloadFolderInputs) {
        _driveFolderInputsFuture = null;
      }
      final folderInputs = await _resolveDriveFolderInputs();
      await _driveSearchGateway.synchronize(
        folderInputs,
        force: force,
        retryFailedExtractions: retryFailedExtractions,
      );
    } catch (_) {
      _setDriveIndexFailure('index_sync_failed');
    }
  }

  void _setDriveIndexFailure(String errorCode) {
    if (!mounted) return;
    setState(() {
      _driveIndexState = DriveSearchIndexState(
        status: SearchIndexStatus.error,
        indexedCount: _driveIndexState.indexedCount,
        totalCount: _driveIndexState.totalCount,
        completedSources: _driveIndexState.completedSources,
        totalSources: _driveIndexState.totalSources,
        lastIndexedAt: _driveIndexState.lastIndexedAt,
        dataRevision: _driveIndexState.dataRevision,
        errorCode: errorCode,
      );
    });
  }

  void _handleDriveIndexStateChanged() {
    if (!mounted) return;
    final previous = _driveIndexState;
    final next = _driveSearchGateway.state;
    final searchableDataChanged =
        previous.dataRevision != next.dataRevision ||
        previous.indexedCount != next.indexedCount ||
        previous.completedSources != next.completedSources ||
        previous.status != next.status;
    final shouldRefreshResults =
        previous.dataRevision != next.dataRevision ||
        previous.indexedCount != next.indexedCount ||
        previous.completedSources != next.completedSources ||
        (previous.status == SearchIndexStatus.indexing &&
            next.status != SearchIndexStatus.indexing);
    setState(() => _driveIndexState = next);

    if (searchableDataChanged) {
      _indexRefreshResults = _indexRefreshResults || shouldRefreshResults;
      _indexRefreshTimer ??= Timer(const Duration(milliseconds: 250), () {
        _indexRefreshTimer = null;
        if (!mounted) return;
        final refreshResults = _indexRefreshResults;
        _indexRefreshResults = false;
        unawaited(_loadSearchFacets());
        if (_hasActiveSearchFilters && refreshResults) {
          _scheduleIndexedSearch(debounce: false, preserveResults: true);
        }
      });
    }
  }

  Future<void> _loadSearchFacets() async {
    final generation = ++_facetLoadGeneration;
    try {
      final authorsFuture = _driveSearchGateway.loadAuthors();
      final genresFuture = _driveSearchGateway.loadGenres();
      final authors = await authorsFuture;
      final genres = await genresFuture;
      if (!mounted || generation != _facetLoadGeneration) return;

      var filtersChanged = false;
      setState(() {
        if (_driveIndexState.status == SearchIndexStatus.ready) {
          if (_selectedAuthor != null && !authors.contains(_selectedAuthor)) {
            _selectedAuthor = null;
            filtersChanged = true;
          }
          final previousGenreCount = _selectedGenres.length;
          _selectedGenres.removeWhere((genre) => !genres.contains(genre));
          filtersChanged =
              filtersChanged || previousGenreCount != _selectedGenres.length;
        }
        _allAuthors = <String>{
          ...authors,
          ?_selectedAuthor,
        }.toList(growable: false);
        _allGenres = [
          'Tất cả',
          ...genres,
          if (_driveIndexState.status != SearchIndexStatus.ready)
            ..._selectedGenres.where((genre) => !genres.contains(genre)),
        ];
      });
      if (filtersChanged) {
        _scheduleIndexedSearch(debounce: false);
      }
    } catch (_) {
      // Existing indexed results remain usable even if facet loading fails.
    }
  }

  bool get _hasActiveSearchFilters =>
      _searchQuery.trim().isNotEmpty ||
      _selectedAuthor != null ||
      _selectedGenres.isNotEmpty;

  void _updateSearchQuery(String value) {
    setState(() => _searchQuery = value);
    _scheduleIndexedSearch();
  }

  void _selectAuthor(String? author) {
    setState(() => _selectedAuthor = author);
    _scheduleIndexedSearch(debounce: false);
  }

  void _scheduleIndexedSearch({
    bool debounce = true,
    bool preserveResults = false,
  }) {
    _searchDebounceTimer?.cancel();
    final generation = ++_searchGeneration;

    if (!_hasActiveSearchFilters) {
      setState(() {
        _indexedSearchStories = [];
        _isSearchLoading = false;
        _isSearchLoadingMore = false;
        _searchHasMore = false;
        _searchError = null;
      });
      return;
    }

    final query = _searchQuery;
    final authors = _selectedAuthor == null
        ? const <String>[]
        : <String>[_selectedAuthor!];
    final genres = _selectedGenres.toList(growable: false);
    setState(() {
      if (!preserveResults) {
        _indexedSearchStories = [];
      }
      _isSearchLoading = true;
      _isSearchLoadingMore = false;
      _searchHasMore = false;
      _searchError = null;
    });

    void run() {
      unawaited(
        _performIndexedSearch(
          generation: generation,
          query: query,
          authors: authors,
          genres: genres,
          offset: 0,
          append: false,
        ),
      );
    }

    if (debounce) {
      _searchDebounceTimer = Timer(_searchDebounce, run);
    } else {
      run();
    }
  }

  void _loadNextSearchPage() {
    if (!_hasActiveSearchFilters ||
        _isSearchLoading ||
        _isSearchLoadingMore ||
        !_searchHasMore) {
      return;
    }

    final generation = _searchGeneration;
    final query = _searchQuery;
    final authors = _selectedAuthor == null
        ? const <String>[]
        : <String>[_selectedAuthor!];
    final genres = _selectedGenres.toList(growable: false);
    setState(() {
      _isSearchLoadingMore = true;
      _searchError = null;
    });
    unawaited(
      _performIndexedSearch(
        generation: generation,
        query: query,
        authors: authors,
        genres: genres,
        offset: _indexedSearchStories.length,
        append: true,
      ),
    );
  }

  Future<void> _performIndexedSearch({
    required int generation,
    required String query,
    required List<String> authors,
    required List<String> genres,
    required int offset,
    required bool append,
  }) async {
    try {
      final page = await _driveSearchGateway.search(
        query: query,
        authors: authors,
        genres: genres,
        limit: _searchPageSize,
        offset: offset,
      );
      if (!mounted || generation != _searchGeneration) return;
      final stories = page.items.map(_storyFromSearchIndex).toList();
      setState(() {
        _indexedSearchStories = append
            ? [..._indexedSearchStories, ...stories]
            : stories;
        _searchHasMore = page.hasMore;
        _searchError = null;
      });
    } catch (error) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searchError = error;
        if (!append) {
          _indexedSearchStories = [];
          _searchHasMore = false;
        }
      });
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _isSearchLoading = false;
          _isSearchLoadingMore = false;
        });
      }
    }
  }

  Story _storyFromSearchIndex(SearchIndexStory indexed) {
    final coverLocalPath = indexed.coverLocalPath?.trim() ?? '';
    final coverUrl = indexed.coverUrl?.trim() ?? '';
    final coverFileId = indexed.coverFileId?.trim() ?? '';
    final iconUrl = coverLocalPath.isNotEmpty
        ? coverLocalPath
        : coverUrl.isNotEmpty
        ? coverUrl
        : coverFileId.isNotEmpty
        ? GoogleDriveService.getCoverImageUrl(coverFileId)
        : '';

    return Story(
      id: indexed.remoteId,
      title: indexed.title,
      description: indexed.description,
      author: indexed.authors.join(', '),
      genres: indexed.genres,
      iconUrl: iconUrl,
      driveFileId: indexed.driveFileId ?? indexed.remoteId,
      isFromDrive: true,
      fileType: _fileTypeFromMimeType(indexed.mimeType),
    );
  }

  String _fileTypeFromMimeType(String mimeType) {
    final normalized = mimeType.trim().toLowerCase();
    if (normalized.contains('epub')) return 'epub';
    if (normalized.contains('pdf')) return 'pdf';
    if (normalized.startsWith('text/')) return 'txt';
    return '';
  }

  Future<void> _loadServerStories() {
    final inFlightLoad = _serverStoriesLoad;
    if (inFlightLoad != null) {
      AppPerformanceLogger.log(
        '[PERF][EXPLORE] Initial page request coalesced',
      );
      return inFlightLoad;
    }

    late final Future<void> load;
    load = _performServerStoriesLoad().whenComplete(() {
      if (identical(_serverStoriesLoad, load)) {
        _serverStoriesLoad = null;
      }
    });
    _serverStoriesLoad = load;
    return load;
  }

  Future<void> _performServerStoriesLoad() async {
    final generation = ++_driveLoadGeneration;
    setState(() {
      _isLoading = true;
      _isLoadingMore = false;
      _isEnrichingMetadata = false;
      _loadError = null;
      _loadMoreError = null;
      _serverStories = [];
      _seenStoryIds.clear();
      _nextPageToken = null;
      _hasMore = true;
    });
    AppPerformanceLogger.log('[PERF][EXPLORE] Initial page start');
    final stopwatch = Stopwatch()..start();

    try {
      final drivePage = await _fetchDrivePage(pageSize: _drivePageSize);
      if (!mounted || generation != _driveLoadGeneration) return;
      for (final story in drivePage.items) {
        final id = story.driveFileId.isNotEmpty ? story.driveFileId : story.id;
        if (_seenStoryIds.add(id)) {
          _serverStories.add(story);
        }
      }
      _nextPageToken = drivePage.nextPageToken;
      _hasMore = drivePage.hasMore;
      stopwatch.stop();
      AppPerformanceLogger.log(
        '[PERF][EXPLORE] Initial page complete: count=${_serverStories.length}, duration=${stopwatch.elapsedMilliseconds}ms, hasMore=$_hasMore',
      );
    } catch (e) {
      if (!mounted || generation != _driveLoadGeneration) return;
      _serverStories = [];
      _loadError = _formatLoadError(e);
    }
    if (!mounted || generation != _driveLoadGeneration) return;
    final plugins = await _loadInstalledPlugins();
    if (!mounted || generation != _driveLoadGeneration) return;
    setState(() {
      _installedPlugins = plugins;
      _isLoading = false;
    });
    unawaited(_enrichMissingDriveMetadata());
  }

  Future<void> _loadNextPage() async {
    final pageToken = _nextPageToken;
    if (_isLoading || _isLoadingMore || !_hasMore || pageToken == null) return;
    final generation = _driveLoadGeneration;
    setState(() {
      _isLoadingMore = true;
      _loadMoreError = null;
    });
    AppPerformanceLogger.log('[PERF][EXPLORE] Next page start');
    final stopwatch = Stopwatch()..start();

    try {
      final drivePage = await _fetchDrivePage(
        pageSize: _drivePageSize,
        pageToken: pageToken,
      );
      if (!mounted || generation != _driveLoadGeneration) return;

      int addedCount = 0;
      for (final story in drivePage.items) {
        final id = story.driveFileId.isNotEmpty ? story.driveFileId : story.id;
        if (_seenStoryIds.add(id)) {
          _serverStories.add(story);
          addedCount++;
        }
      }
      _nextPageToken = drivePage.nextPageToken;
      _hasMore = drivePage.hasMore;
      stopwatch.stop();
      AppPerformanceLogger.log(
        '[PERF][EXPLORE] Next page complete: added=$addedCount, total=${_serverStories.length}, duration=${stopwatch.elapsedMilliseconds}ms, hasMore=$_hasMore',
      );
    } catch (e) {
      if (!mounted || generation != _driveLoadGeneration) return;
      _loadMoreError = e;
      AppPerformanceLogger.log('[PERF][EXPLORE] Page load error: $e');
    } finally {
      if (mounted && generation == _driveLoadGeneration) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  Future<void> _refreshServerStories() async {
    if (_serverStoriesLoad != null || _isLoading) {
      AppPerformanceLogger.log('[PERF][EXPLORE] Refresh request coalesced');
      return;
    }
    unawaited(_synchronizeDriveSearch(force: true));
    AppPerformanceLogger.log('[PERF][EXPLORE] Refresh page start');
    final refresh = _loadServerStories();
    final generation = _driveLoadGeneration;
    await refresh;
    if (mounted &&
        generation == _driveLoadGeneration &&
        !_isLoading &&
        _loadError == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã làm mới danh sách truyện!')),
      );
    }
  }

  String _formatLoadError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.contains('GOOGLE_DRIVE_API_KEY')) {
      return 'Chưa cấu hình khóa truy cập Drive. Hãy thêm key vào .env trên Android hoặc tham số build.';
    }
    if (message.contains('GOOGLE_DRIVE_FOLDER_URL')) {
      return 'Chưa cấu hình thư mục truyện trên Drive. Hãy kiểm tra link thư mục dùng cho bản demo.';
    }
    return message;
  }

  List<Story> get _displayStories =>
      _hasActiveSearchFilters ? _indexedSearchStories : _serverStories;

  void _toggleGenre(String genre) {
    if (genre == _allGenres.first) {
      setState(() {
        _selectedGenres.clear();
      });
      _scheduleIndexedSearch(debounce: false);
      return;
    }

    setState(() {
      if (_selectedGenres.contains(genre)) {
        _selectedGenres.remove(genre);
      } else {
        _selectedGenres.add(genre);
      }
    });
    _scheduleIndexedSearch(debounce: false);
  }

  Future<void> _enrichMissingDriveMetadata({bool force = false}) async {
    if (_isEnrichingMetadata || _serverStories.isEmpty) return;
    final generation = _driveLoadGeneration;
    final targets = _serverStories
        .where(
          (story) =>
              story.isFromDrive &&
              story.driveFileId.trim().isNotEmpty &&
              story.fileType.trim().toLowerCase() == 'epub' &&
              (force ||
                  story.genres.isEmpty ||
                  story.description.trim().isEmpty ||
                  story.author.trim().isEmpty ||
                  story.totalChapters <= 1 ||
                  story.iconUrl.trim().isEmpty ||
                  story.iconUrl.trim().startsWith('assets/')),
        )
        .take(12)
        .toList();
    if (targets.isEmpty) return;

    setState(() => _isEnrichingMetadata = true);
    try {
      for (final story in targets) {
        final enriched = await ApiService.enrichDriveStoryMetadata(
          story,
          force: force,
        );
        if (!mounted || generation != _driveLoadGeneration) return;
        final index = _serverStories.indexWhere(
          (item) =>
              item.id == enriched.id ||
              (item.driveFileId.isNotEmpty &&
                  item.driveFileId == enriched.driveFileId),
        );
        if (index == -1) continue;
        if (_storyMetadataChanged(_serverStories[index], enriched)) {
          _serverStories[index] = enriched;
        }
      }
    } finally {
      if (mounted && generation == _driveLoadGeneration) {
        setState(() => _isEnrichingMetadata = false);
      }
    }
  }

  bool _storyMetadataChanged(Story before, Story after) {
    return before.iconUrl != after.iconUrl ||
        before.description != after.description ||
        before.author != after.author ||
        before.totalChapters != after.totalChapters ||
        before.genres.join('|') != after.genres.join('|');
  }

  Future<void> _importFromDriveDialog() async {
    final urlController = TextEditingController();
    try {
      final inputs = await ApiService.getSavedDriveStoryFolderInputs();
      if (urlController.text.isEmpty && inputs.isNotEmpty) {
        urlController.text = inputs.join('\n');
      }
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Quét thư mục Google Drive'),
            content: TextField(
              controller: urlController,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                hintText:
                    'Dán link Drive. Link admin nhập sẽ được lưu để lần sau tự cập nhật.',
              ),
            ),
            actions: [
              TextButton(
                child: const Text('Hủy'),
                onPressed: () => Navigator.pop(dialogContext),
              ),
              TextButton(
                child: const Text('Tạo catalog.json'),
                onPressed: () async {
                  final inputText = urlController.text;
                  Navigator.pop(dialogContext);
                  setState(() => _isLoading = true);
                  try {
                    final folderUrls = inputText
                        .trim()
                        .split('\n')
                        .map((e) => e.trim())
                        .where((e) => e.isNotEmpty)
                        .toList();
                    if (folderUrls.isEmpty) throw Exception('Vui lòng nhập link');
                    if (folderUrls.length > 1) {
                      throw Exception(
                          'Vui lòng xóa các link cũ, chỉ để lại 1 link duy nhất (link thư mục của bạn) để tạo catalog.');
                    }
                    
                    await ApiService.saveDriveStoryFolderInputs(inputText, overwrite: true);
                    final folderUrl = folderUrls.first;
                    
                    final driveStories = await ApiService.fetchDriveStoriesFromFolder(folderUrl);
                    await GoogleDriveService.uploadCatalogToFolder(folderUrl, driveStories);
                    
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Row(
                            children: [
                              Icon(Icons.check_circle, color: Colors.white),
                              SizedBox(width: 12),
                              Expanded(child: Text('Đã tạo và upload catalog.json thành công!', style: TextStyle(color: Colors.white))),
                            ],
                          ),
                          backgroundColor: Colors.green,
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Row(
                            children: [
                              const Icon(Icons.error_outline, color: Colors.white),
                              const SizedBox(width: 12),
                              Expanded(child: Text('Lỗi: $e', style: const TextStyle(color: Colors.white))),
                            ],
                          ),
                          backgroundColor: Colors.red.shade700,
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  } finally {
                    if (mounted) setState(() => _isLoading = false);
                  }
                },
              ),
              TextButton(
                child: const Text('Quét'),
                onPressed: () async {
                  final inputText = urlController.text;
                  Navigator.pop(dialogContext);
                  setState(() => _isLoading = true);
                  try {
                    await ApiService.saveDriveStoryFolderInputs(inputText, overwrite: true);
                    final driveStories =
                        await ApiService.fetchDriveStoriesFromFolder(
                          inputText,
                        );
                    _serverStories = driveStories;
                    _seenStoryIds
                      ..clear()
                      ..addAll(
                        driveStories.map(
                          (story) => story.driveFileId.isNotEmpty
                              ? story.driveFileId
                              : story.id,
                        ),
                      );
                    _nextPageToken = null;
                    _hasMore = false;
                    _loadError = null;
                    unawaited(
                      _synchronizeDriveSearch(
                        force: true,
                        reloadFolderInputs: true,
                      ),
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Đã tải ${driveStories.length} truyện từ Google Drive!',
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    _serverStories = [];
                    _loadError = _formatLoadError(e);
                    if (mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('Lỗi: $e')));
                    }
                  }
                  if (mounted) {
                    setState(() => _isLoading = false);
                    unawaited(_enrichMissingDriveMetadata());
                  }
                },
              ),
            ],
          );
        },
      );
    } finally {
      urlController.dispose();
    }
  }

  Future<void> _openExtensionManager() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ExtensionScreen()),
    );
    final updated = await ExtensionService.getInstalledPlugins();
    if (mounted) {
      setState(() {
        _installedPlugins = updated;
      });
    }
  }

  void _showOnlineSourcePicker() {
    final plugins = _installedPlugins;
    if (plugins.isEmpty) {
      _openExtensionManager();
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          builder: (_, controller) {
            return Container(
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.language_rounded,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Chọn nguồn truyện',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.extension_rounded, size: 18),
                        label: const Text('Kho Extension'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _openExtensionManager();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      controller: controller,
                      itemCount: plugins.length,
                      itemBuilder: (context, index) {
                        final plugin = plugins[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: colorScheme.primary.withValues(
                              alpha: 0.12,
                            ),
                            child: Icon(
                              Icons.extension_rounded,
                              color: colorScheme.primary,
                            ),
                          ),
                          title: Text(
                            plugin.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            plugin.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    SourceBrowseScreen(plugin: plugin),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final accentColor = colorScheme.primary;
    final userProvider = context.watch<UserProvider>();

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        titleSpacing: 16,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Tên, tác giả hoặc tag...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
                style: TextStyle(color: colorScheme.onSurface, fontSize: 16),
                onChanged: _updateSearchQuery,
              )
            : Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: isDark
                          ? colorScheme.surfaceContainerHighest
                          : Colors.white,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.menu_book, size: 18),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Khám phá',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 20,
                      ),
                    ),
                  ),
                  if (userProvider.isAdmin) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: accentColor.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        'Admin',
                        style: TextStyle(
                          color: accentColor,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
        actions: [
          if (_isSearching)
            IconButton(
              icon: const Icon(Icons.manage_search),
              tooltip: 'Tìm nhiều nguồn',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => UnifiedSearchScreen(
                    initialQuery: _searchQuery,
                    driveSearchGateway: _driveSearchGateway,
                    gateway: AppUnifiedSearchGateway(
                      drive: _driveSearchGateway,
                      loadPlugins: _loadInstalledPlugins,
                    ),
                  ),
                ),
              ),
            ),
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              final clearSearch = _isSearching;
              setState(() {
                if (_isSearching) {
                  _isSearching = false;
                  _searchQuery = '';
                  _searchController.clear();
                } else {
                  _isSearching = true;
                }
              });
              if (clearSearch) {
                _scheduleIndexedSearch(debounce: false);
              }
            },
          ),
          if (!_isSearching) ...[
            IconButton(
              icon: const Icon(Icons.language_rounded),
              onPressed: _showOnlineSourcePicker,
              tooltip: 'Truyện Online',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _isLoading ? null : _refreshServerStories,
              tooltip: 'Làm mới Drive',
            ),
            if (userProvider.isAdmin)
              IconButton(
                icon: const Icon(Icons.add_link),
                onPressed: _importFromDriveDialog,
                tooltip: 'Quét thư mục Drive',
              ),
          ],
        ],
      ),
      body: _isLoading && !_hasActiveSearchFilters
          ? const AppLoadingState(message: 'Đang tải danh sách truyện...')
          : NotificationListener<ScrollNotification>(
              onNotification: (scrollInfo) {
                if (scrollInfo.metrics.pixels >=
                    scrollInfo.metrics.maxScrollExtent - 300) {
                  if (_hasActiveSearchFilters) {
                    _loadNextSearchPage();
                  } else if (!_isLoadingMore &&
                      _hasMore &&
                      _loadMoreError == null) {
                    _loadNextPage();
                  }
                }
                return false;
              },
              child: CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: _buildSourceDashboard(
                      isDark: isDark,
                      accentColor: accentColor,
                      isAdmin: userProvider.isAdmin,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _buildDriveIndexStatus(accentColor: accentColor),
                  ),
                  SliverToBoxAdapter(
                    child: _buildOnlineSourceSection(
                      isDark: isDark,
                      accentColor: accentColor,
                    ),
                  ),
                  if (_allAuthors.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _AuthorFilterBar(
                        authors: _allAuthors,
                        selectedAuthor: _selectedAuthor,
                        onChanged: _selectAuthor,
                      ),
                    ),
                  if (_allGenres.length > 1)
                    SliverToBoxAdapter(
                      child: _GenreChipBar(
                        genres: _allGenres,
                        selectedGenres: _selectedGenres,
                        accentColor: accentColor,
                        isDark: isDark,
                        onSelect: _toggleGenre,
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: _buildResultHeader(isDark, accentColor),
                    ),
                  ),
                  ..._buildSliverStoryGrid(isDark),
                ],
              ),
            ),
    );
  }

  Widget _buildOnlineSourceSection({
    required bool isDark,
    required Color accentColor,
  }) {
    final plugins = _installedPlugins;
    final colorScheme = Theme.of(context).colorScheme;

    if (plugins.isEmpty) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border(
            bottom: BorderSide(
              color: colorScheme.outline.withValues(alpha: 0.10),
            ),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _openExtensionManager,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accentColor.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.extension_rounded, color: accentColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Kho Extension Nguồn Truyện Online',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Chưa cài Extension. Bấm để khám phá & tải nguồn truyện!',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: accentColor),
              ],
            ),
          ),
        ),
      );
    }

    final baseStyle = Theme.of(context).textTheme.bodyMedium!;
    final titleStyle = baseStyle.copyWith(
      fontWeight: FontWeight.bold,
      fontSize: 13,
      color: colorScheme.onSurface,
    );
    final versionStyle = baseStyle.copyWith(
      fontSize: 11,
      color: colorScheme.onSurfaceVariant,
    );
    double lineHeight(TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: 'Ag', style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final cardHeight = (lineHeight(titleStyle) + lineHeight(versionStyle) + 24)
        .ceilToDouble()
        .clamp(68.0, double.infinity);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.10),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.language_rounded,
                  color: accentColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Nguồn truyện Online',
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _showOnlineSourcePicker,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Xem tất cả'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: cardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: plugins.length,
              separatorBuilder: (context, index) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final plugin = plugins[index];
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SourceBrowseScreen(plugin: plugin),
                      ),
                    );
                  },
                  child: Container(
                    width: 200,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? colorScheme.surfaceContainerHighest
                          : colorScheme.surfaceContainerHighest.withValues(
                              alpha: 0.6,
                            ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: accentColor.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: accentColor.withValues(alpha: 0.14),
                          child: Icon(
                            Icons.extension_rounded,
                            color: accentColor,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                plugin.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: titleStyle,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'v${plugin.version}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: versionStyle,
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right, size: 18, color: accentColor),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceDashboard({
    required bool isDark,
    required Color accentColor,
    required bool isAdmin,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final epubCount = _serverStories
        .where((story) => story.fileType.toLowerCase() == 'epub')
        .length;
    final pdfCount = _serverStories
        .where((story) => story.fileType.toLowerCase() == 'pdf')
        .length;
    final txtCount = _serverStories
        .where((story) => story.fileType.toLowerCase() == 'txt')
        .length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.10),
          ),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.cloud_queue_rounded, color: accentColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nguồn truyện Drive',
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Quét thư mục, lọc thể loại và mở truyện trực tiếp',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                onPressed: _isLoading ? null : _refreshServerStories,
                tooltip: 'Làm mới Drive',
                icon: const Icon(Icons.refresh_rounded),
              ),
              if (isAdmin) ...[
                const SizedBox(width: 6),
                IconButton.filled(
                  onPressed: _importFromDriveDialog,
                  tooltip: 'Quét thư mục Drive',
                  icon: const Icon(Icons.add_link_rounded),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SourceStatPill(
                  label: 'Tổng',
                  value: '${_serverStories.length}',
                  color: accentColor,
                  icon: Icons.menu_book_rounded,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SourceStatPill(
                  label: 'EPUB',
                  value: '$epubCount',
                  color: const Color(0xFF4E8F7E),
                  icon: Icons.article_rounded,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SourceStatPill(
                  label: 'PDF',
                  value: '$pdfCount',
                  color: const Color(0xFFB45D5D),
                  icon: Icons.picture_as_pdf_rounded,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SourceStatPill(
                  label: 'TXT',
                  value: '$txtCount',
                  color: const Color(0xFF8A6F34),
                  icon: Icons.text_snippet_rounded,
                  isDark: isDark,
                ),
              ),
            ],
          ),
          if (_isEnrichingMetadata) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 3,
                color: accentColor,
                backgroundColor: accentColor.withValues(alpha: 0.14),
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Đang cập nhật tag EPUB...',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDriveIndexStatus({required Color accentColor}) {
    final state = _driveIndexState;
    final colorScheme = Theme.of(context).colorScheme;
    late final IconData icon;
    late final String title;
    late final String message;
    late final Color statusColor;
    late final bool canRetry;

    final indexedLabel = state.totalCount == null
        ? '${state.indexedCount} truyện'
        : '${state.indexedCount}/${state.totalCount} truyện';
    final sourceLabel = state.totalSources == 0
        ? ''
        : ' · ${state.completedSources}/${state.totalSources} nguồn';

    switch (state.status) {
      case SearchIndexStatus.notStarted:
        icon = Icons.storage_rounded;
        title = 'Chưa có chỉ mục tìm kiếm';
        message =
            'Tìm kiếm sẽ khả dụng khi dữ liệu Drive đầu tiên được lập chỉ mục.';
        statusColor = colorScheme.onSurfaceVariant;
        canRetry = true;
        break;
      case SearchIndexStatus.indexing:
        icon = Icons.sync_rounded;
        title = 'Đang lập chỉ mục thư viện';
        message =
            '$indexedLabel$sourceLabel · Kết quả hiện tại có thể chưa đầy đủ.';
        statusColor = accentColor;
        canRetry = false;
        break;
      case SearchIndexStatus.ready:
        icon = Icons.check_circle_outline_rounded;
        title = 'Chỉ mục tìm kiếm đã sẵn sàng';
        message = '$indexedLabel$sourceLabel';
        statusColor = const Color(0xFF43866F);
        canRetry = false;
        break;
      case SearchIndexStatus.partial:
        icon = Icons.info_outline_rounded;
        title = 'Chỉ mục chưa hoàn tất';
        message =
            '$indexedLabel$sourceLabel · Vẫn có thể tìm trong dữ liệu đã lưu.';
        statusColor = const Color(0xFFA56A17);
        canRetry = true;
        break;
      case SearchIndexStatus.error:
        icon = Icons.error_outline_rounded;
        title = 'Không thể cập nhật chỉ mục';
        message = state.indexedCount > 0
            ? '$indexedLabel$sourceLabel · Vẫn có thể tìm trong dữ liệu cũ.'
            : 'Kiểm tra kết nối hoặc cấu hình Drive rồi thử lại.';
        statusColor = colorScheme.error;
        canRetry = true;
        break;
    }

    final progress =
        state.status == SearchIndexStatus.indexing && state.totalSources > 0
        ? state.completedSources / state.totalSources
        : null;

    return Container(
      key: const ValueKey('drive-index-status'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.07),
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.10),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: statusColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              if (canRetry)
                IconButton(
                  key: const ValueKey('drive-index-retry'),
                  onPressed: () => unawaited(
                    _synchronizeDriveSearch(
                      force: true,
                      retryFailedExtractions: true,
                    ),
                  ),
                  tooltip: 'Thử lập chỉ mục lại, gồm metadata bị lỗi',
                  icon: const Icon(Icons.refresh_rounded),
                ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              color: statusColor,
              backgroundColor: statusColor.withValues(alpha: 0.14),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLoadErrorState() {
    return AppErrorState(
      icon: Icons.cloud_off_rounded,
      title: 'Không tải được danh sách truyện',
      message: _loadError ?? 'Vui lòng kiểm tra kết nối hoặc cấu hình Drive.',
      actionLabel: 'Thử lại',
      onAction: _loadServerStories,
    );
  }

  Widget _buildResultHeader(bool isDark, Color accentColor) {
    final stories = _displayStories;
    final isFiltered = _hasActiveSearchFilters;
    final selectedLabels = <String>[?_selectedAuthor, ..._selectedGenres];
    final selectedLabel = selectedLabels.isEmpty
        ? ''
        : selectedLabels.length <= 3
        ? selectedLabels.join(', ')
        : '${selectedLabels.take(3).join(', ')} +${selectedLabels.length - 3}';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isFiltered ? 'Kết quả tìm kiếm' : 'Mới cập nhật',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${stories.length} truyện${selectedLabel.isNotEmpty ? ' · $selectedLabel' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
        if (isFiltered && _isSearchLoading) ...[
          const SizedBox(width: 8),
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
        if (isFiltered)
          TextButton.icon(
            onPressed: () {
              setState(() {
                _searchQuery = '';
                _searchController.clear();
                _selectedGenres.clear();
                _selectedAuthor = null;
                _isSearching = false;
              });
              _scheduleIndexedSearch(debounce: false);
            },
            icon: const Icon(Icons.filter_alt_off, size: 16),
            label: const Text('Xóa lọc', style: TextStyle(fontSize: 13)),
            style: TextButton.styleFrom(
              foregroundColor: accentColor,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildSliverStoryGrid(bool isDark) {
    final stories = _displayStories;
    final isFiltered = _hasActiveSearchFilters;

    if (!isFiltered && _loadError != null && _serverStories.isEmpty) {
      return [_buildStoryStateSliver(_buildLoadErrorState())];
    }

    if (isFiltered && _isSearchLoading && stories.isEmpty) {
      return [
        _buildStoryStateSliver(
          const AppLoadingState(message: 'Đang tìm trong chỉ mục...'),
          height: 180,
        ),
      ];
    }

    if (isFiltered && _searchError != null && stories.isEmpty) {
      return [
        _buildStoryStateSliver(
          AppErrorState(
            icon: Icons.storage_rounded,
            title: 'Không thể tìm trong chỉ mục',
            message: 'Dữ liệu tìm kiếm chưa đọc được. Vui lòng thử lại.',
            actionLabel: 'Thử lại',
            onAction: () => _scheduleIndexedSearch(debounce: false),
          ),
        ),
      ];
    }

    if (stories.isEmpty) {
      return [
        _buildStoryStateSliver(
          AppEmptyState(
            icon: Icons.search_off_rounded,
            title: 'Không tìm thấy truyện',
            message:
                _driveIndexState.status == SearchIndexStatus.indexing ||
                    _driveIndexState.status == SearchIndexStatus.partial
                ? 'Chưa có kết quả trong phần dữ liệu đã lập chỉ mục. Thử lại khi chỉ mục cập nhật thêm.'
                : 'Thử tìm bằng tên truyện, tác giả hoặc bỏ bớt bộ lọc.',
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.50,
            crossAxisSpacing: 12,
            mainAxisSpacing: 16,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            final story = stories[index];
            return _StoryCard(
              key: ValueKey(
                story.driveFileId.isNotEmpty ? story.driveFileId : story.id,
              ),
              story: story,
              isDark: isDark,
            );
          }, childCount: stories.length),
        ),
      ),
      if (isFiltered && _isSearchLoadingMore)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 4),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Đang tải thêm kết quả...',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        )
      else if (isFiltered && _searchError != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 4),
            child: Center(
              child: TextButton.icon(
                onPressed: _searchHasMore
                    ? _loadNextSearchPage
                    : () => _scheduleIndexedSearch(debounce: false),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Không tải được thêm. Thử lại'),
              ),
            ),
          ),
        )
      else if (isFiltered && !_searchHasMore)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 8),
            child: Center(
              child: Text(
                _driveIndexState.status == SearchIndexStatus.ready
                    ? 'Đã hiển thị hết kết quả'
                    : 'Đã hiển thị hết kết quả hiện có trong chỉ mục',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        )
      else if (!isFiltered && _isLoadingMore)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 4),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Đang tải thêm truyện từ Drive...',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
      else if (!isFiltered && _loadMoreError != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 4),
            child: Center(
              child: TextButton.icon(
                onPressed: _loadNextPage,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Không tải được thêm. Thử lại'),
              ),
            ),
          ),
        )
      else if (!isFiltered && !_hasMore && stories.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 8),
            child: Center(
              child: Text(
                'Đã tải hết danh sách truyện',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _buildStoryStateSliver(Widget child, {double height = 300}) {
    return SliverToBoxAdapter(
      child: SizedBox(height: height, child: child),
    );
  }
}

class _AuthorFilterBar extends StatelessWidget {
  const _AuthorFilterBar({
    required this.authors,
    required this.selectedAuthor,
    required this.onChanged,
  });

  final List<String> authors;
  final String? selectedAuthor;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.10),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.person_search_rounded,
            size: 20,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            'Tác giả',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const ValueKey('drive-author-filter'),
                value: selectedAuthor ?? '',
                isExpanded: true,
                menuMaxHeight: 360,
                items: [
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text(
                      'Tất cả tác giả',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final author in authors)
                    DropdownMenuItem<String>(
                      value: author,
                      child: Text(
                        author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) =>
                    onChanged(value == null || value.isEmpty ? null : value),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GenreChipBar extends StatelessWidget {
  final List<String> genres;
  final Set<String> selectedGenres;
  final Color accentColor;
  final bool isDark;
  final ValueChanged<String> onSelect;

  const _GenreChipBar({
    required this.genres,
    required this.selectedGenres,
    required this.accentColor,
    required this.isDark,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? Colors.white10
                : Colors.black.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: genres.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final genre = genres[index];
          final isSelected = index == 0
              ? selectedGenres.isEmpty
              : selectedGenres.contains(genre);
          return GestureDetector(
            onTap: () => onSelect(genre),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected
                    ? accentColor
                    : (isDark ? const Color(0xFF2A2A2A) : Colors.grey.shade100),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected
                      ? accentColor
                      : (isDark ? Colors.white12 : Colors.grey.shade300),
                  width: 1,
                ),
              ),
              child: Text(
                index == 0 && selectedGenres.isNotEmpty ? 'Bỏ lọc' : genre,
                style: TextStyle(
                  color: isSelected
                      ? Colors.white
                      : (isDark ? Colors.grey.shade300 : Colors.grey.shade700),
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SourceStatPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;
  final bool isDark;

  const _SourceStatPill({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B19) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _StoryCard extends StatelessWidget {
  final Story story;
  final bool isDark;

  const _StoryCard({super.key, required this.story, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final type = story.fileType.isEmpty ? 'EPUB' : story.fileType.toUpperCase();
    final chapterText = story.totalChapters > 1
        ? '${story.totalChapters} chương'
        : type;

    return GestureDetector(
      onTap: () async {
        if (story.pluginId.isNotEmpty && story.storyUrl.isNotEmpty) {
          final installed = await ExtensionService.getInstalledPlugins();
          final plugin = installed.firstWhere(
            (p) => p.id == story.pluginId,
            orElse: () => PluginInfo(
              id: story.pluginId,
              name: story.pluginId,
              version: 1,
              author: 'vBook',
              description: '',
              iconUrl: '',
              downloadUrl: '',
              locale: 'vi',
              source: '',
              type: story.fileType == 'comic' ? 'comic' : 'novel',
            ),
          );
          if (!context.mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => OnlineStoryDetailScreen(
                plugin: plugin,
                storyUrl: story.storyUrl,
                initialTitle: story.title,
                initialCover: story.iconUrl,
              ),
            ),
          );
          return;
        }
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => StoryDetailScreen(story: story)),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                StoryCoverImage(
                  imagePath: story.iconUrl,
                  driveFileId: story.driveFileId,
                  fileType: story.fileType,
                  width: double.infinity,
                  height: double.infinity,
                  borderRadius: BorderRadius.circular(8),
                  backgroundColor: isDark
                      ? Colors.grey.shade800
                      : Colors.grey.shade300,
                ),
                Positioned(
                  top: 6,
                  left: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      type,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.70),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      chapterText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            story.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              height: 1.25,
              color: colorScheme.onSurface,
            ),
          ),
          if (story.author.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              story.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
