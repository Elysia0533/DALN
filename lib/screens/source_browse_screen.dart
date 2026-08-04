import 'dart:io';
import 'package:flutter/material.dart';
import '../models/plugin_info.dart';
import '../services/plugin/vbook_engine_channel.dart';
import '../services/plugin/plugin_loader.dart';
import '../services/extension_service.dart';
import '../models/source_models.dart';
import '../widgets/story_cover_image.dart';
import 'online_story_detail_screen.dart';
import 'web_browser_screen.dart';
import 'extension_screen.dart';

class SourceBrowseScreen extends StatefulWidget {
  final PluginInfo plugin;

  const SourceBrowseScreen({super.key, required this.plugin});

  @override
  State<SourceBrowseScreen> createState() => _SourceBrowseScreenState();
}

class _SourceBrowseScreenState extends State<SourceBrowseScreen> {
  late PluginInfo _currentPlugin;
  List<PluginInfo> _installedPlugins = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _error;
  List<SManga> _stories = [];
  bool _isSearching = false;
  bool _hasNextPage = false;
  int _currentPage = 1;
  String _currentSearchQuery = '';

  // Dynamic tabs returned from extension home.js
  List<Map<String, String>> _dynamicTabs = [];
  // 0: Tab 0, 1: Tab 1, etc.
  int _selectedTab = 0;
  // 0: Grid 3 cột, 1: Grid 2 cột, 2: Danh sách
  int _layoutMode = 0;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _currentPlugin = widget.plugin;
    _scrollController.addListener(_onScroll);
    _loadInstalledPlugins();
    _loadHome();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInstalledPlugins() async {
    final list = await ExtensionService.getInstalledPlugins();
    if (mounted) {
      setState(() {
        _installedPlugins = list;
      });
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 300 &&
        !_isLoadingMore &&
        _hasNextPage) {
      _loadMore();
    }
  }

  /// Ensures the plugin is downloaded and loaded into the native engine.
  Future<bool> _ensurePluginLoaded(PluginInfo plugin) async {
    final baseDirPath = await PluginLoader.getPluginDir(plugin.id);
    final baseDir = Directory(baseDirPath);

    String effectiveDirPath = baseDirPath;
    bool pluginJsonFound = await File('$baseDirPath/plugin.json').exists();

    if (!pluginJsonFound && await baseDir.exists()) {
      try {
        final subDirs = await baseDir.list().where((e) => e is Directory).toList();
        for (final subDir in subDirs) {
          if (await File('${subDir.path}/plugin.json').exists()) {
            effectiveDirPath = subDir.path;
            pluginJsonFound = true;
            print('[SourceBrowse] Found plugin.json in subdirectory: $effectiveDirPath');
            break;
          }
        }
      } catch (e) {
        print('[SourceBrowse] Error scanning subdirs: $e');
      }
    }

    if (!await baseDir.exists() || !pluginJsonFound) {
      print('[SourceBrowse] Plugin dir missing for ${plugin.id}, downloading...');
      final downloadUrl = plugin.downloadUrl;
      if (downloadUrl.isEmpty) {
        throw Exception('Không có URL tải plugin. Vui lòng gỡ và cài lại từ kho Extension.');
      }
      final result = await PluginLoader.installPlugin(downloadUrl, plugin.id);
      if (result == null) {
        throw Exception('Không thể tải plugin. Kiểm tra kết nối mạng.');
      }
      effectiveDirPath = result;
    }

    print('[SourceBrowse] Loading engine with path: $effectiveDirPath');

    final success = await VBookEngineChannel.loadSource(plugin.id.hashCode, effectiveDirPath);
    if (!success) {
      throw Exception('Engine load failed for ${plugin.id}. Check logcat for details.');
    }
    return true;
  }

  Future<void> _loadHome([int? tabIndex]) async {
    final targetTab = tabIndex ?? _selectedTab;
    setState(() {
      _selectedTab = targetTab;
      _isLoading = true;
      _error = null;
      _currentPage = 1;
      _currentSearchQuery = '';
      _hasNextPage = false;
    });

    try {
      await _ensurePluginLoaded(_currentPlugin);

      if (_dynamicTabs.isEmpty) {
        final tabs = await VBookEngineChannel.getHomeTabs(_currentPlugin.id.hashCode);
        if (tabs.isNotEmpty) {
          _dynamicTabs = tabs;
        }
      }

      MangasPage? page;
      if (_dynamicTabs.isNotEmpty && targetTab < _dynamicTabs.length) {
        final tab = _dynamicTabs[targetTab];
        page = await VBookEngineChannel.getMangaListByTab(
          _currentPlugin.id.hashCode,
          tab['input'] ?? '',
          tab['script'] ?? 'gen.js',
          1,
        );
      } else if (targetTab == 0) {
        // Thử lấy danh sách mới cập nhật trước
        page = await VBookEngineChannel.getLatestUpdates(_currentPlugin.id.hashCode, 1);
        // Nếu kết quả rỗng, fallback sang popular
        if (page == null || page.mangas.isEmpty) {
          page = await VBookEngineChannel.getPopularManga(_currentPlugin.id.hashCode, 1);
        }
      } else {
        page = await VBookEngineChannel.getPopularManga(_currentPlugin.id.hashCode, 1);
      }

      if (mounted) {
        setState(() {
          _stories = page?.mangas ?? [];
          _hasNextPage = page?.hasNextPage ?? false;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore) return;
    setState(() => _isLoadingMore = true);

    try {
      final nextPage = _currentPage + 1;
      MangasPage? page;
      if (_currentSearchQuery.isNotEmpty) {
        page = await VBookEngineChannel.getSearchManga(
            _currentPlugin.id.hashCode, _currentSearchQuery, nextPage);
      } else if (_dynamicTabs.isNotEmpty && _selectedTab < _dynamicTabs.length) {
        final tab = _dynamicTabs[_selectedTab];
        page = await VBookEngineChannel.getMangaListByTab(
          _currentPlugin.id.hashCode,
          tab['input'] ?? '',
          tab['script'] ?? 'gen.js',
          nextPage,
        );
      } else if (_selectedTab == 0) {
        page = await VBookEngineChannel.getLatestUpdates(
            _currentPlugin.id.hashCode, nextPage);
        if (page == null || page.mangas.isEmpty) {
          page = await VBookEngineChannel.getPopularManga(
              _currentPlugin.id.hashCode, nextPage);
        }
      } else {
        page = await VBookEngineChannel.getPopularManga(
            _currentPlugin.id.hashCode, nextPage);
      }

      if (mounted) {
        setState(() {
          _stories.addAll(page?.mangas ?? []);
          _hasNextPage = page?.hasNextPage ?? false;
          _currentPage = nextPage;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      _loadHome();
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
      _currentPage = 1;
      _currentSearchQuery = query.trim();
      _hasNextPage = false;
    });
    try {
      await _ensurePluginLoaded(_currentPlugin);
      final page = await VBookEngineChannel.getSearchManga(
          _currentPlugin.id.hashCode, query.trim(), 1);
      if (mounted) {
        setState(() {
          _stories = page?.mangas ?? [];
          _hasNextPage = page?.hasNextPage ?? false;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _switchPlugin(PluginInfo plugin) {
    if (_currentPlugin.id == plugin.id) return;
    setState(() {
      _currentPlugin = plugin;
      _dynamicTabs = [];
      _selectedTab = 0;
    });
    _loadHome();
  }

  Future<void> _openBrowser() async {
    final baseUrl = _currentPluginBaseUrl();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebBrowserScreen(
          initialUrl: baseUrl,
          title: _currentPlugin.name,
        ),
      ),
    );
    if (mounted) {
      _loadHome();
    }
  }

  String _currentPluginBaseUrl() {
    final source = _currentPlugin.source;
    if (source.isNotEmpty && source.startsWith('http')) return source;
    if (source.contains("hako") || _currentPlugin.id.contains("hako")) {
      return 'https://docln.sbs';
    }
    return 'https://google.com';
  }

  void _showPluginSelectorBottomSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Tất cả phần mở rộng',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ExtensionScreen()),
                          ).then((_) => _loadInstalledPlugins());
                        },
                        icon: const Icon(Icons.settings, size: 18),
                        label: const Text('Quản lý'),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                if (_installedPlugins.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('Chưa có extension nào được cài đặt')),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _installedPlugins.length,
                      itemBuilder: (context, index) {
                        final plugin = _installedPlugins[index];
                        final isSelected = plugin.id == _currentPlugin.id;
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(context).primaryColor.withOpacity(0.15),
                            child: Icon(Icons.extension_rounded,
                                color: Theme.of(context).primaryColor),
                          ),
                          title: Text(
                            plugin.name,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text('${plugin.type} • v${plugin.version}'),
                          trailing: isSelected
                              ? Icon(Icons.check_circle,
                                  color: Theme.of(context).primaryColor)
                              : null,
                          onTap: () {
                            Navigator.pop(context);
                            _switchPlugin(plugin);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showOptionsMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Layout Mode selector row (Grid 3, Grid 2, List)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildLayoutToggleButton(
                      icon: Icons.grid_on_rounded,
                      label: '3 Cột',
                      isSelected: _layoutMode == 0,
                      onTap: () {
                        setState(() => _layoutMode = 0);
                        Navigator.pop(context);
                      },
                    ),
                    _buildLayoutToggleButton(
                      icon: Icons.grid_view_rounded,
                      label: '2 Cột',
                      isSelected: _layoutMode == 1,
                      onTap: () {
                        setState(() => _layoutMode = 1);
                        Navigator.pop(context);
                      },
                    ),
                    _buildLayoutToggleButton(
                      icon: Icons.view_list_rounded,
                      label: 'Danh sách',
                      isSelected: _layoutMode == 2,
                      onTap: () {
                        setState(() => _layoutMode = 2);
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.extension_outlined),
                  title: const Text('T.cả phần mở rộng'),
                  onTap: () {
                    Navigator.pop(context);
                    _showPluginSelectorBottomSheet();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.open_in_browser_rounded),
                  title: const Text('Trang nguồn'),
                  subtitle: Text(_currentPlugin.source),
                  onTap: () {
                    Navigator.pop(context);
                    _openBrowser();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLayoutToggleButton({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final primaryColor = Theme.of(context).primaryColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? primaryColor.withOpacity(0.18)
              : Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? primaryColor : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: isSelected ? primaryColor : null),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? primaryColor : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Tìm kiếm truyện...',
                  border: InputBorder.none,
                ),
                onSubmitted: _search,
              )
            : InkWell(
                onTap: _showPluginSelectorBottomSheet,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          _currentPlugin.name,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.keyboard_arrow_down_rounded, size: 22),
                    ],
                  ),
                ),
              ),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchController.clear();
                  _loadHome();
                }
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Tùy chọn hiển thị & nguồn',
            onPressed: _showOptionsMenu,
          ),
        ],
      ),
      body: Column(
        children: [
          // Sub-header category / tab bar (Mới cập nhật | Phổ biến | Dynamic tabs from extension)
          if (!_isSearching)
            Container(
              height: 48,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context).dividerColor.withOpacity(0.12),
                  ),
                ),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: _dynamicTabs.isNotEmpty
                      ? List.generate(_dynamicTabs.length, (index) {
                          final tab = _dynamicTabs[index];
                          return Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: _buildTabChip(
                              label: tab['title'] ?? 'Tab ${index + 1}',
                              isSelected: _selectedTab == index,
                              onTap: () => _loadHome(index),
                            ),
                          );
                        })
                      : [
                          _buildTabChip(
                            label: 'Mới cập nhật',
                            isSelected: _selectedTab == 0,
                            onTap: () => _loadHome(0),
                          ),
                          const SizedBox(width: 10),
                          _buildTabChip(
                            label: 'Phổ biến',
                            isSelected: _selectedTab == 1,
                            onTap: () => _loadHome(1),
                          ),
                        ],
                ),
              ),
            ),

          // Main story content grid/list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _buildErrorWidget()
                    : _stories.isEmpty
                        ? _buildEmptyWidget()
                        : RefreshIndicator(
                            onRefresh: _loadHome,
                            child: _layoutMode == 2
                                ? _buildListView(isDark)
                                : _buildGridView(isDark),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final primaryColor = Theme.of(context).primaryColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? primaryColor : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? primaryColor : Theme.of(context).textTheme.bodyMedium?.color,
          ),
        ),
      ),
    );
  }

  Widget _buildGridView(bool isDark) {
    final crossCount = _layoutMode == 0 ? 3 : 2;
    final childRatio = _layoutMode == 0 ? 0.56 : 0.64;

    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(10),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossCount,
        childAspectRatio: childRatio,
        crossAxisSpacing: 10,
        mainAxisSpacing: 12,
      ),
      itemCount: _stories.length + (_hasNextPage || _isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _stories.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final story = _stories[index];
        return GestureDetector(
          onTap: () => _openStoryDetail(story),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: StoryCoverImage(
                    imagePath: story.thumbnailUrl,
                    width: double.infinity,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                story.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
              ),
              if (story.description.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  story.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.grey[400] : Colors.grey[700],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildListView(bool isDark) {
    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: _stories.length + (_hasNextPage || _isLoadingMore ? 1 : 0),
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index >= _stories.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final story = _stories[index];
        return InkWell(
          onTap: () => _openStoryDetail(story),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: StoryCoverImage(
                    imagePath: story.thumbnailUrl,
                    width: 70,
                    height: 100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        story.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      if (story.description.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          story.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.grey[400] : Colors.grey[700],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openStoryDetail(SManga story) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OnlineStoryDetailScreen(
          plugin: _currentPlugin,
          storyUrl: story.url,
          initialTitle: story.title,
          initialCover: story.thumbnailUrl,
        ),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Không tải được nội dung',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Text(
              'Trang web có thể yêu cầu đăng nhập hoặc VPN.\nBạn có thể mở trình duyệt để đăng nhập tài khoản ${_currentPlugin.name}.',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openBrowser,
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Mở trình duyệt & Đăng nhập'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _loadHome(),
              icon: const Icon(Icons.refresh),
              label: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.search_off_rounded,
              size: 64,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            const Text(
              'Không tìm thấy dữ liệu',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Chưa thể tải dữ liệu từ ${_currentPlugin.name}.\nWebsite có thể phản hồi chậm hoặc chặn kết nối ngầm.\nHãy thử đổi tab "Phổ biến", bấm "Thử lại" hoặc mở trình duyệt.',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () => _loadHome(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Thử lại'),
                ),
                if (_selectedTab == 0) ...[
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () => _loadHome(1),
                    icon: const Icon(Icons.local_fire_department, size: 18),
                    label: const Text('Xem Phổ biến'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _openBrowser,
              icon: const Icon(Icons.open_in_browser, size: 18),
              label: Text('Mở trình duyệt ${_currentPlugin.name}'),
            ),
          ],
        ),
      ),
    );
  }
}
