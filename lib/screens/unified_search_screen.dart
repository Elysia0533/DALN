import 'dart:async';

import 'package:flutter/material.dart';

import '../models/search_index_state.dart';
import '../models/unified_search.dart';
import '../services/search/drive_search_coordinator.dart';
import '../services/search/unified_search_controller.dart';
import '../services/search/unified_search_gateway.dart';
import '../widgets/story_cover_image.dart';
import 'online_story_detail_screen.dart';
import 'story_detail_screen.dart';

class UnifiedSearchScreen extends StatefulWidget {
  const UnifiedSearchScreen({
    super.key,
    this.initialQuery = '',
    this.gateway,
    this.driveSearchGateway,
    this.onOpenResult,
  });

  final String initialQuery;
  final UnifiedSearchGateway? gateway;
  final DriveSearchGateway? driveSearchGateway;
  final ValueChanged<SearchResult>? onOpenResult;

  @override
  State<UnifiedSearchScreen> createState() => _UnifiedSearchScreenState();
}

class _UnifiedSearchScreenState extends State<UnifiedSearchScreen> {
  late final TextEditingController _text;
  late final DriveSearchGateway _drive;
  late final UnifiedSearchGateway _gateway;
  late final UnifiedSearchController _controller;
  late DriveSearchIndexState _driveState;
  Timer? _driveRefreshTimer;
  List<SearchSource> _sources = [
    AppUnifiedSearchGateway.driveSource,
    AppUnifiedSearchGateway.localSource,
  ];
  final Set<String> _selected = {AppUnifiedSearchGateway.driveSource.key};
  SearchFacets _facets = SearchFacets();
  String? _author;
  String? _genre;
  bool _loadingSources = true;
  bool _sourceError = false;
  bool _loadingFacets = false;
  bool _facetError = false;
  int _facetGeneration = 0;

  List<SearchSource> get _selection =>
      _sources.where((s) => _selected.contains(s.key)).toList();
  bool get _authorEnabled =>
      _selection.isNotEmpty &&
      _selection.every((s) => s.capabilities.supportsAuthor);
  bool get _genreEnabled =>
      _selection.isNotEmpty &&
      _selection.every((s) => s.capabilities.supportsGenre);

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initialQuery);
    _drive = widget.driveSearchGateway ?? DriveSearchCoordinator.instance;
    _gateway = widget.gateway ?? AppUnifiedSearchGateway(drive: _drive);
    _controller = UnifiedSearchController(_gateway)..addListener(_changed);
    _driveState = _drive.state;
    _drive.addListener(_driveChanged);
    unawaited(_loadSources());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _driveChanged() {
    if (!mounted) return;
    final previous = _driveState;
    final next = _drive.state;
    setState(() => _driveState = next);
    final changed =
        previous.dataRevision != next.dataRevision ||
        previous.indexedCount != next.indexedCount ||
        previous.completedSources != next.completedSources ||
        (previous.status == SearchIndexStatus.indexing &&
            next.status != SearchIndexStatus.indexing);
    if (!changed || _driveRefreshTimer != null) return;
    // Coalesce fast SQLite commits without restarting extension searches.
    _driveRefreshTimer = Timer(const Duration(milliseconds: 250), () {
      _driveRefreshTimer = null;
      if (!mounted ||
          _loadingSources ||
          !_selected.contains(AppUnifiedSearchGateway.driveSource.key)) {
        return;
      }
      unawaited(_loadFacets());
      unawaited(
        _controller.refreshSource(AppUnifiedSearchGateway.driveSource.key),
      );
    });
  }

  Future<void> _loadSources() async {
    setState(() {
      _loadingSources = true;
      _sourceError = false;
    });
    try {
      final sources = await _gateway.loadSources();
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _selected.removeWhere((key) => !sources.any((s) => s.key == key));
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _sourceError = true);
    }
    if (!mounted) return;
    setState(() => _loadingSources = false);
    unawaited(_loadFacets());
    unawaited(_submit());
  }

  Future<void> _loadFacets() async {
    final generation = ++_facetGeneration;
    final selection = _selection;
    setState(() {
      _facets = SearchFacets();
      _facetError = false;
      _loadingFacets = true;
    });
    try {
      final facets = await Future.wait([
        for (final source in selection)
          if (source.capabilities.supportsAuthor ||
              source.capabilities.supportsGenre)
            _gateway.facets(source),
      ]);
      if (!mounted || generation != _facetGeneration) return;
      setState(() {
        _facets = SearchFacets(
          authors: facets.expand((f) => f.authors).toSet().toList()..sort(),
          genres: facets.expand((f) => f.genres).toSet().toList()..sort(),
        );
      });
    } catch (_) {
      if (mounted && generation == _facetGeneration) {
        setState(() => _facetError = true);
      }
    } finally {
      if (mounted && generation == _facetGeneration) {
        setState(() => _loadingFacets = false);
      }
    }
  }

  Future<void> _submit() {
    FocusManager.instance.primaryFocus?.unfocus();
    return _controller.search(
      _selection,
      UnifiedSearchQuery(text: _text.text, author: _author, genre: _genre),
    );
  }

  Future<void> _chooseSources() async {
    final draft = Set<String>.of(_selected);
    final enabled = _sources
        .where((s) => s.capabilities.supportsKeyword)
        .map((s) => s.key)
        .toSet();
    final chosen = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .8,
              child: Column(
                children: [
                  CheckboxListTile(
                    title: const Text('Tất cả nguồn'),
                    value: enabled.isNotEmpty && draft.containsAll(enabled),
                    onChanged: enabled.isEmpty
                        ? null
                        : (value) => update(() {
                            value == true
                                ? draft.addAll(enabled)
                                : draft.clear();
                          }),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final source in _sources)
                          CheckboxListTile(
                            key: ValueKey('source-${source.key}'),
                            title: Text(source.name),
                            subtitle: enabled.contains(source.key)
                                ? null
                                : const Text('Không hỗ trợ tìm kiếm'),
                            value: draft.contains(source.key),
                            onChanged: !enabled.contains(source.key)
                                ? null
                                : (value) => update(() {
                                    value == true
                                        ? draft.add(source.key)
                                        : draft.remove(source.key);
                                  }),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Hủy'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: draft.isEmpty
                                ? null
                                : () => Navigator.pop(context, draft),
                            icon: const Icon(Icons.check),
                            label: const Text('Áp dụng'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || chosen == null) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(chosen);
      _author = null;
      _genre = null;
    });
    unawaited(_loadFacets());
    unawaited(_submit());
  }

  Future<void> _open(SearchResult result) async {
    if (widget.onOpenResult != null) {
      widget.onOpenResult!(result);
      return;
    }
    final plugin = result.source.plugin;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            result.source.type == SearchSourceType.extension && plugin != null
            ? OnlineStoryDetailScreen(
                plugin: plugin,
                storyUrl: result.remoteId,
                initialTitle: result.title,
                initialCover: result.cover,
              )
            : StoryDetailScreen(story: result.story),
      ),
    );
  }

  @override
  void dispose() {
    _facetGeneration++;
    _driveRefreshTimer?.cancel();
    _drive.removeListener(_driveChanged);
    _controller.removeListener(_changed);
    _controller.dispose();
    _text.dispose();
    super.dispose();
  }

  Widget _filter({
    required String label,
    required String keyName,
    required bool enabled,
    required List<String> values,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      key: ValueKey('$keyName-${value ?? ''}-${values.join('|')}'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        DropdownMenuItem<String>(
          value: null,
          child: Text('Tất cả $label', overflow: TextOverflow.ellipsis),
        ),
        for (final item in {...values, ?value})
          DropdownMenuItem(
            value: item,
            child: Text(item, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled && !_loadingFacets && !_facetError ? onChanged : null,
    );
  }

  Widget _driveStatus() {
    final state = _drive.state;
    final status = switch (state.status) {
      SearchIndexStatus.notStarted => 'Chưa có chỉ mục Drive',
      SearchIndexStatus.indexing =>
        'Drive đang lập chỉ mục: ${state.indexedCount}',
      SearchIndexStatus.ready => 'Chỉ mục Drive: ${state.indexedCount} truyện',
      SearchIndexStatus.partial =>
        'Chỉ mục Drive chưa đầy đủ: ${state.indexedCount} truyện',
      SearchIndexStatus.error =>
        'Lỗi cập nhật chỉ mục Drive. Đang dùng dữ liệu đã lưu.',
    };
    return Row(
      children: [
        Expanded(
          child: Text(status, style: Theme.of(context).textTheme.bodySmall),
        ),
        IconButton(
          tooltip: 'Cập nhật kết quả từ chỉ mục',
          onPressed: () {
            unawaited(_loadFacets());
            unawaited(_submit());
          },
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Tìm kiếm nhiều nguồn',
          style: TextStyle(fontSize: 18),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: CustomScrollView(
          key: const ValueKey('unified-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const ValueKey('unified-query'),
                      controller: _text,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _submit(),
                      onChanged: (_) => _controller.clear(),
                      decoration: InputDecoration(
                        labelText: 'Tên truyện',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          key: const ValueKey('unified-submit'),
                          tooltip: 'Tìm kiếm',
                          onPressed: _loadingSources || _selection.isEmpty
                              ? null
                              : _submit,
                          icon: const Icon(Icons.search),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('unified-sources'),
                        onPressed: _loadingSources ? null : _chooseSources,
                        icon: const Icon(Icons.manage_search),
                        label: Text('Nguồn (${_selected.length})'),
                      ),
                    ),
                    if (_loadingSources) const LinearProgressIndicator(),
                    if (_sourceError)
                      Row(
                        children: [
                          const Expanded(
                            child: Text('Không tải được danh sách extension.'),
                          ),
                          IconButton(
                            tooltip: 'Tải lại nguồn',
                            onPressed: _loadSources,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final filters = [
                          _filter(
                            label: 'tác giả',
                            keyName: 'author',
                            enabled: _authorEnabled,
                            values: _facets.authors,
                            value: _author,
                            onChanged: (value) {
                              setState(() => _author = value);
                              unawaited(_submit());
                            },
                          ),
                          _filter(
                            label: 'thể loại',
                            keyName: 'genre',
                            enabled: _genreEnabled,
                            values: _facets.genres,
                            value: _genre,
                            onChanged: (value) {
                              setState(() => _genre = value);
                              unawaited(_submit());
                            },
                          ),
                        ];
                        return constraints.maxWidth < 440
                            ? Column(
                                children: [
                                  filters.first,
                                  const SizedBox(height: 12),
                                  filters.last,
                                ],
                              )
                            : Row(
                                children: [
                                  Expanded(child: filters.first),
                                  const SizedBox(width: 12),
                                  Expanded(child: filters.last),
                                ],
                              );
                      },
                    ),
                    if (_loadingFacets) const LinearProgressIndicator(),
                    if (_facetError)
                      Row(
                        children: [
                          const Expanded(child: Text('Không tải được bộ lọc.')),
                          IconButton(
                            tooltip: 'Tải lại bộ lọc',
                            onPressed: _loadFacets,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    if (_selection.any((s) => s.type == SearchSourceType.drive))
                      _driveStatus(),
                  ],
                ),
              ),
            ),
            for (final state in _controller.states) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.source.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text('${state.items.length}'),
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: state.items.length,
                itemBuilder: (context, index) {
                  final result = state.items[index];
                  return ListTile(
                    key: ValueKey(result.stableId),
                    leading: StoryCoverImage(
                      imagePath: result.cover,
                      width: 40,
                      height: 56,
                    ),
                    title: Text(
                      result.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: result.author.isEmpty
                        ? null
                        : Text(
                            result.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () => _open(result),
                  );
                },
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (state.status == SourceSearchStatus.loading)
                        const LinearProgressIndicator(),
                      if (state.message != null) Text(state.message!),
                      if (state.status == SourceSearchStatus.ready &&
                          state.items.isEmpty)
                        const Text('Không có kết quả trong dữ liệu hiện có.'),
                      if (state.status == SourceSearchStatus.error)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () =>
                                _controller.retry(state.source.key),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Thử lại'),
                          ),
                        )
                      else if (state.nextPage != null &&
                          state.status != SourceSearchStatus.loading)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () =>
                                _controller.loadMore(state.source.key),
                            icon: const Icon(Icons.expand_more),
                            label: const Text('Tải thêm'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: Divider(height: 1)),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}
