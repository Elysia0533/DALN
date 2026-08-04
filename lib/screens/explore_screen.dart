import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/story.dart';
import '../services/api_service.dart';
import '../services/extension_service.dart';
import '../models/plugin_info.dart';
import '../theme/user_provider.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/story_cover_image.dart';
import 'source_browse_screen.dart';
import 'story_detail_screen.dart';
import 'extension_screen.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  List<Story> _serverStories = [];
  bool _isLoading = true;
  bool _isSearching = false;
  bool _isEnrichingMetadata = false;
  String? _loadError;
  List<PluginInfo> _installedPlugins = [];

  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  List<String> _allGenres = ['Tất cả'];
  final Set<String> _selectedGenres = {};

  @override
  void initState() {
    super.initState();
    _loadServerStories();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadServerStories() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      _serverStories = await ApiService.fetchServerStories();
      _buildGenreList();
    } catch (e) {
      _serverStories = [];
      _allGenres = ['Tất cả'];
      _selectedGenres.clear();
      _loadError = _formatLoadError(e);
    }
    if (mounted) {
      final plugins = await ExtensionService.getInstalledPlugins();
      setState(() {
        _installedPlugins = plugins;
        _isLoading = false;
      });
      unawaited(_enrichMissingDriveMetadata());
    }
  }

  Future<void> _refreshServerStories() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      _serverStories = await ApiService.refreshServerStories();
      _buildGenreList();
      _loadError = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã làm mới danh sách truyện!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Lỗi làm mới: $e')));
      }
      _loadError = _formatLoadError(e);
    }
    if (mounted) {
      setState(() => _isLoading = false);
      unawaited(_enrichMissingDriveMetadata());
    }
  }

  String _formatLoadError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.contains('GOOGLE_DRIVE_API_KEY')) {
      return 'Chưa cấu hình khóa truy cập Drive. Hãy kiểm tra tham số chạy app trước khi build APK demo.';
    }
    if (message.contains('GOOGLE_DRIVE_FOLDER_URL')) {
      return 'Chưa cấu hình thư mục truyện trên Drive. Hãy kiểm tra link thư mục dùng cho bản demo.';
    }
    return message;
  }

  void _buildGenreList() {
    final genreSet = <String>{};
    for (final story in _serverStories) {
      for (final genre in story.genres) {
        final trimmed = genre.trim();
        if (trimmed.isNotEmpty) genreSet.add(trimmed);
      }
    }
    final sorted = genreSet.toList()..sort();
    _allGenres = ['Tất cả', ...sorted];
    _selectedGenres.removeWhere((genre) => !genreSet.contains(genre));
  }

  List<Story> get _displayStories {
    final selectedKeys = _selectedGenres.map(_genreKey).toSet();
    return _serverStories.where((s) {
      final storyGenreKeys = s.genres.map(_genreKey).toSet();
      final genreMatch =
          selectedKeys.isEmpty ||
          storyGenreKeys.any((genre) => selectedKeys.contains(genre));

      final q = _searchQuery.trim().toLowerCase();
      final searchText = [
        s.title,
        s.author,
        s.description,
        s.fileType,
        ...s.genres,
      ].join(' ').toLowerCase();
      final textMatch = q.isEmpty || searchText.contains(q);

      return genreMatch && textMatch;
    }).toList();
  }

  String _genreKey(String value) => value.trim().toLowerCase();

  void _toggleGenre(String genre) {
    if (genre == _allGenres.first) {
      setState(_selectedGenres.clear);
      return;
    }

    setState(() {
      if (_selectedGenres.contains(genre)) {
        _selectedGenres.remove(genre);
      } else {
        _selectedGenres.add(genre);
      }
    });
  }

  Future<void> _enrichMissingDriveMetadata({bool force = false}) async {
    if (_isEnrichingMetadata || _serverStories.isEmpty) return;
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
    var changed = false;
    try {
      for (final story in targets) {
        final enriched = await ApiService.enrichDriveStoryMetadata(
          story,
          force: force,
        );
        if (!mounted) return;
        final index = _serverStories.indexWhere(
          (item) =>
              item.id == enriched.id ||
              (item.driveFileId.isNotEmpty &&
                  item.driveFileId == enriched.driveFileId),
        );
        if (index == -1) continue;
        if (_storyMetadataChanged(_serverStories[index], enriched)) {
          _serverStories[index] = enriched;
          changed = true;
        }
      }
    } finally {
      if (mounted) {
        if (changed) _buildGenreList();
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

  void _importFromDriveDialog() {
    TextEditingController urlController = TextEditingController();
    ApiService.getSavedDriveStoryFolderInputs().then((inputs) {
      if (urlController.text.isEmpty && inputs.isNotEmpty) {
        urlController.text = inputs.join('\n');
      }
    });
    showDialog(
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
              child: const Text('Quét'),
              onPressed: () async {
                Navigator.pop(dialogContext);
                setState(() => _isLoading = true);
                try {
                  final driveStories =
                      await ApiService.fetchDriveStoriesFromFolder(
                        urlController.text,
                      );
                  _serverStories = driveStories;
                  _buildGenreList();
                  _loadError = null;
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
                  _buildGenreList();
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
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  Container(
                    width: 36, height: 4,
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
                          Icon(Icons.language_rounded, color: colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            'Chọn nguồn truyện',
                            style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold,
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
                            backgroundColor: colorScheme.primary.withValues(alpha: 0.12),
                            child: Icon(Icons.extension_rounded, color: colorScheme.primary),
                          ),
                          title: Text(plugin.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(plugin.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
                          onTap: () {
                            Navigator.pop(ctx);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => SourceBrowseScreen(plugin: plugin),
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
                onChanged: (value) => setState(() => _searchQuery = value),
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
                  const Text(
                    'Khám phá',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
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
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                if (_isSearching) {
                  _isSearching = false;
                  _searchQuery = '';
                  _searchController.clear();
                } else {
                  _isSearching = true;
                }
              });
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
              onPressed: _refreshServerStories,
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
      body: _isLoading
          ? const AppLoadingState(message: 'Đang tải danh sách truyện...')
          : _loadError != null && _serverStories.isEmpty
          ? _buildLoadErrorState()
          : CustomScrollView(
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
                  child: _buildOnlineSourceSection(isDark: isDark, accentColor: accentColor),
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
                _buildSliverStoryGrid(isDark),
              ],
            ),
    );
  }

  Widget _buildOnlineSourceSection({required bool isDark, required Color accentColor}) {
    final plugins = _installedPlugins;
    final colorScheme = Theme.of(context).colorScheme;

    if (plugins.isEmpty) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border(
            bottom: BorderSide(color: colorScheme.outline.withValues(alpha: 0.10)),
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
              border: Border.all(
                color: accentColor.withValues(alpha: 0.25),
              ),
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

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: colorScheme.outline.withValues(alpha: 0.10)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.language_rounded, color: accentColor, size: 20),
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
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 68,
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
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isDark
                          ? colorScheme.surfaceContainerHighest
                          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
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
                          child: Icon(Icons.extension_rounded, color: accentColor, size: 20),
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
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'v${plugin.version}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colorScheme.onSurfaceVariant,
                                ),
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
                onPressed: _refreshServerStories,
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
    final isFiltered =
        _searchQuery.trim().isNotEmpty || _selectedGenres.isNotEmpty;
    final selectedLabel = _selectedGenres.isEmpty
        ? ''
        : _selectedGenres.length <= 3
        ? _selectedGenres.join(', ')
        : '${_selectedGenres.take(3).join(', ')} +${_selectedGenres.length - 3}';

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
        if (isFiltered)
          TextButton.icon(
            onPressed: () {
              setState(() {
                _searchQuery = '';
                _searchController.clear();
                _selectedGenres.clear();
                _isSearching = false;
              });
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

  Widget _buildSliverStoryGrid(bool isDark) {
    final stories = _displayStories;

    if (stories.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: AppEmptyState(
          icon: Icons.search_off_rounded,
          title: 'Không tìm thấy truyện',
          message: _searchQuery.isNotEmpty
              ? 'Thử tìm bằng tên truyện, tác giả hoặc bỏ bớt bộ lọc.'
              : 'Thể loại này hiện chưa có truyện trong danh sách.',
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.50,
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final story = stories[index];
            return _StoryCard(story: story, isDark: isDark);
          },
          childCount: stories.length,
        ),
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

  const _StoryCard({required this.story, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final type = story.fileType.isEmpty ? 'EPUB' : story.fileType.toUpperCase();
    final chapterText = story.totalChapters > 1
        ? '${story.totalChapters} chương'
        : type;

    return GestureDetector(
      onTap: () {
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
