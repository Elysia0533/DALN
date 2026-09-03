import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/plugin_info.dart';
import '../services/extension_service.dart';
import 'source_browse_screen.dart';

Future<bool> showExtensionCleartextWarningDialog(
  BuildContext context, {
  required String host,
  required String actionLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Canh bao ket noi HTTP'),
      content: Text(
        'URL nay su dung HTTP cho "$host". Noi dung co the bi doc hoac bi '
        'thay doi tren duong truyen.\n\n'
        'Chi tiep tuc neu ban tin tuong nguon nay.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Huy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(actionLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}

void _showExtensionUrlError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<ExtensionUrlValidationResult?> confirmUserProvidedExtensionUrl(
  BuildContext context,
  String input, {
  required String actionLabel,
}) async {
  final validation = ExtensionService.validateUserProvidedUrl(input);
  if (!validation.isValid) {
    _showExtensionUrlError(context, validation.errorMessage!);
    return null;
  }

  if (!validation.isCleartext) return validation;

  final confirmed = await showExtensionCleartextWarningDialog(
    context,
    host: validation.host,
    actionLabel: actionLabel,
  );
  if (!confirmed) return null;
  return validation;
}

class ExtensionScreen extends StatefulWidget {
  const ExtensionScreen({super.key});

  @override
  State<ExtensionScreen> createState() => _ExtensionScreenState();
}

class _ExtensionScreenState extends State<ExtensionScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<PluginInfo> _allPlugins = [];
  List<PluginInfo> _installedPlugins = [];
  bool _isLoading = false;
  String? _error;
  String _searchQuery = '';
  bool _isSearching = false;
  String _typeFilter = 'all'; // all | novel | comic | chinese_novel
  bool _hideNsfw = true;

  static const _prefKeyHideNsfw = 'ext_hide_nsfw';

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() {}));
    _loadNsfwPref();
    _loadExtensions();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadNsfwPref() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _hideNsfw = prefs.getBool(_prefKeyHideNsfw) ?? true;
    });
  }

  Future<void> _saveNsfwPref(bool hide) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyHideNsfw, hide);
  }

  /// Bật hiển thị 18+ cần xác nhận tuổi
  Future<void> _toggleNsfw() async {
    if (_hideNsfw) {
      // Đang ẩn → muốn hiện → cần xác nhận tuổi
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Xác nhận tuổi'),
          content: const Text(
            'Một số extension có nội dung dành cho người trưởng thành (18+).\n\n'
            'Bạn có đủ 18 tuổi và đồng ý xem nội dung này không?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Không, thoát'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Tôi đủ 18 tuổi'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final newValue = !_hideNsfw;
    setState(() => _hideNsfw = newValue);
    await _saveNsfwPref(newValue);
  }

  Future<void> _loadExtensions({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        ExtensionService.fetchAllRegistries(),
        ExtensionService.getInstalledPlugins(),
      ]);
      setState(() {
        _allPlugins = (results[0] as List).cast<PluginInfo>();
        _installedPlugins = (results[1] as List).cast<PluginInfo>();
      });
    } catch (e) {
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<PluginInfo> get _filteredPlugins {
    var list = _tabController.index == 0 ? _allPlugins : _installedPlugins;

    // Hide NSFW
    if (_hideNsfw) list = list.where((p) => !p.isNsfw).toList();

    // Type filter
    if (_typeFilter != 'all') {
      list = list.where((p) => p.type == _typeFilter).toList();
    }

    // Search
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase().trim();
      list = list
          .where(
            (p) =>
                p.name.toLowerCase().contains(q) ||
                p.source.toLowerCase().contains(q) ||
                p.description.toLowerCase().contains(q),
          )
          .toList();
    }

    return list;
  }

  Future<void> _installPlugin(PluginInfo plugin) async {
    setState(() => _isLoading = true);
    try {
      await ExtensionService.installPlugin(plugin);
      await _loadExtensions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã cài đặt thành công "${plugin.name}"!'),
            backgroundColor: Colors.green.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lỗi cài đặt: ${e.toString().replaceAll('Exception: ', '')}',
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _uninstallPlugin(PluginInfo plugin) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Gỡ Extension?'),
        content: Text('Gỡ cài đặt "${plugin.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Gỡ', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await ExtensionService.uninstallPlugin(plugin.id);
      await _loadExtensions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã gỡ "${plugin.name}"'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Không thể gỡ extension: ${error.toString().replaceFirst('Exception: ', '')}',
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _installFromLocalZip() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null || result.files.isEmpty) return;
      final filePath = result.files.single.path;
      if (filePath == null) return;

      setState(() => _isLoading = true);
      final plugin = await ExtensionService.installFromZipFile(File(filePath));
      await _loadExtensions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã cài đặt extension "${plugin.name}" từ file ZIP!'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lỗi cài đặt ZIP: ${e.toString().replaceAll('Exception: ', '')}',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _installFromZipUrl() async {
    final urlController = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cài đặt Extension từ URL ZIP'),
        content: TextField(
          controller: urlController,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/extension.zip',
            labelText: 'URL file .zip',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, urlController.text.trim()),
            child: const Text('Tải & Cài'),
          ),
        ],
      ),
    );

    if (url == null || url.isEmpty) return;
    if (!mounted) return;

    final validation = await confirmUserProvidedExtensionUrl(
      context,
      url,
      actionLabel: 'Tiep tuc cai dat',
    );
    if (!mounted || validation == null) return;

    setState(() => _isLoading = true);
    try {
      final plugin = await ExtensionService.installFromZipUrl(validation.url);
      await _loadExtensions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã cài đặt "${plugin.name}" từ URL!'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lỗi tải URL ZIP: ${e.toString().replaceAll('Exception: ', '')}',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showInstallMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.folder_zip_rounded, color: Colors.blue),
              title: const Text('Cài đặt từ file .ZIP (Bộ nhớ thiết bị)'),
              subtitle: const Text('Chọn file extension .zip đã tải về'),
              onTap: () {
                Navigator.pop(ctx);
                _installFromLocalZip();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded, color: Colors.purple),
              title: const Text('Cài đặt từ URL file .ZIP trực tiếp'),
              subtitle: const Text(
                'Nhập đường dẫn URL tới file .zip extension',
              ),
              onTap: () {
                Navigator.pop(ctx);
                _installFromZipUrl();
              },
            ),
            ListTile(
              leading: const Icon(Icons.manage_search, color: Colors.orange),
              title: const Text('Quản lý kho Nguồn (Registry URL)'),
              subtitle: const Text('Thêm / Xóa các kho extension online'),
              onTap: () {
                Navigator.pop(ctx);
                _showRegistryManager();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRegistryManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _RegistryManagerSheet(
        onChanged: () {
          Navigator.pop(ctx);
          _loadExtensions(forceRefresh: true);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showInstallMenu,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Thêm Extension'),
      ),
      appBar: AppBar(
        titleSpacing: 16,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Tìm extension...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
                style: TextStyle(color: colorScheme.onSurface, fontSize: 16),
                onChanged: (v) => setState(() => _searchQuery = v),
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
                    child: const Icon(Icons.extension, size: 18),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Extensions',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
                  ),
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
            // Nút ẩn/hiện 18+ nhanh trong AppBar
            Tooltip(
              message: _hideNsfw
                  ? 'Đang ẩn 18+ — Nhấn để hiện'
                  : 'Đang hiện 18+ — Nhấn để ẩn',
              child: InkWell(
                onTap: _toggleNsfw,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _hideNsfw
                        ? Colors.grey.withValues(alpha: 0.15)
                        : Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _hideNsfw
                          ? Colors.grey.withValues(alpha: 0.4)
                          : Colors.red.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _hideNsfw ? Icons.visibility_off : Icons.visibility,
                        size: 14,
                        color: _hideNsfw ? Colors.grey : Colors.red,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '18+',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: _hideNsfw ? Colors.grey : Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.filter_list),
              tooltip: 'Lọc',
              onPressed: _showFilterSheet,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Làm mới',
              onPressed: () => _loadExtensions(forceRefresh: true),
            ),
            IconButton(
              icon: const Icon(Icons.manage_search),
              tooltip: 'Quản lý kho',
              onPressed: _showRegistryManager,
            ),
          ],
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              text:
                  'Tất cả (${_allPlugins.where((p) => _hideNsfw ? !p.isNsfw : true).length})',
            ),
            Tab(text: 'Đã cài (${_installedPlugins.length})'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _allPlugins.isEmpty
          ? _buildErrorState()
          : TabBarView(
              controller: _tabController,
              children: [
                _buildPluginList(_filteredPlugins, showAll: true),
                _buildPluginList(_filteredPlugins, showAll: false),
              ],
            ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 72, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Không tải được danh sách Extension',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _loadExtensions,
              icon: const Icon(Icons.refresh),
              label: const Text('Thử lại'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPluginList(List<PluginInfo> plugins, {required bool showAll}) {
    if (plugins.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.extension_off, size: 64, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              showAll
                  ? 'Không tìm thấy extension nào'
                  : 'Chưa cài extension nào',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
            if (!showAll) ...[
              const SizedBox(height: 8),
              const Text(
                'Chuyển sang tab "Tất cả" để duyệt và cài extension',
                style: TextStyle(fontSize: 13, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: plugins.length,
      separatorBuilder: (context, index) =>
          const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) {
        final plugin = plugins[index];
        return _PluginTile(
          plugin: plugin,
          onInstall: () => _installPlugin(plugin),
          onUninstall: () => _uninstallPlugin(plugin),
        );
      },
    );
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _FilterSheet(
        typeFilter: _typeFilter,
        hideNsfw: _hideNsfw,
        onToggleNsfw: () async {
          Navigator.pop(ctx); // đóng sheet trước
          await _toggleNsfw(); // gọi age gate nếu cần
        },
        onApply: (type) {
          setState(() => _typeFilter = type);
          Navigator.pop(ctx);
        },
      ),
    );
  }
}

// ── Plugin Tile ──
class _PluginTile extends StatelessWidget {
  final PluginInfo plugin;
  final VoidCallback onInstall;
  final VoidCallback onUninstall;

  const _PluginTile({
    required this.plugin,
    required this.onInstall,
    required this.onUninstall,
  });

  Color get _typeColor {
    switch (plugin.type) {
      case 'novel':
        return Colors.blue;
      case 'comic':
        return Colors.orange;
      case 'chinese_novel':
        return Colors.red;
      case 'tts':
        return Colors.purple;
      case 'video':
        return Colors.teal;
      default:
        return Colors.grey;
    }
  }

  String get _typeLabel {
    switch (plugin.type) {
      case 'novel':
        return 'Truyện chữ';
      case 'comic':
        return 'Manga';
      case 'chinese_novel':
        return 'Tiếng Trung';
      case 'tts':
        return 'TTS';
      case 'video':
        return 'Video';
      default:
        return plugin.type;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subColor = isDark ? Colors.grey.shade400 : Colors.grey.shade600;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: plugin.isInstalled
          ? () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SourceBrowseScreen(plugin: plugin),
                ),
              );
            }
          : null,
      leading: _buildIcon(),
      title: Row(
        children: [
          Flexible(
            child: Text(
              plugin.name,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: textColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _typeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _typeLabel,
              style: TextStyle(
                fontSize: 10,
                color: _typeColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (plugin.isNsfw) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red.shade700.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '18+',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
          if (plugin.hasUpdate) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.shade700.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Cập nhật',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.green.shade700,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            plugin.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: subColor),
          ),
          const SizedBox(height: 2),
          Text(
            'v${plugin.version} · ${plugin.source}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: subColor.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
      trailing: plugin.isInstalled
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.tonal(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SourceBrowseScreen(plugin: plugin),
                      ),
                    );
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 32),
                  ),
                  child: const Text('Duyệt'),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (val) {
                    if (val == 'update') onInstall();
                    if (val == 'uninstall') onUninstall();
                  },
                  itemBuilder: (_) => [
                    if (plugin.hasUpdate)
                      const PopupMenuItem(
                        value: 'update',
                        child: ListTile(
                          leading: Icon(
                            Icons.system_update,
                            color: Colors.green,
                          ),
                          title: Text('Cập nhật'),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'uninstall',
                      child: ListTile(
                        leading: Icon(Icons.delete_outline, color: Colors.red),
                        title: Text('Gỡ cài đặt'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                    ),
                  ],
                ),
              ],
            )
          : IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: 'Cài đặt',
              onPressed: onInstall,
            ),
    );
  }

  Widget _buildIcon() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: plugin.iconUrl.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: plugin.iconUrl,
              width: 46,
              height: 46,
              fit: BoxFit.cover,
              errorWidget: (ctx, url, err) =>
                  _PlaceholderIcon(type: plugin.type),
              placeholder: (ctx, url) => _PlaceholderIcon(type: plugin.type),
            )
          : _PlaceholderIcon(type: plugin.type),
    );
  }
}

class _PlaceholderIcon extends StatelessWidget {
  final String type;
  const _PlaceholderIcon({required this.type});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    IconData icon;
    switch (type) {
      case 'comic':
        icon = Icons.image;
        break;
      case 'tts':
        icon = Icons.headphones;
        break;
      case 'video':
        icon = Icons.play_circle;
        break;
      default:
        icon = Icons.book;
    }
    return Container(
      width: 46,
      height: 46,
      color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
      child: Icon(
        icon,
        size: 22,
        color: isDark ? Colors.white38 : Colors.black38,
      ),
    );
  }
}

// ── Filter Bottom Sheet ──
class _FilterSheet extends StatefulWidget {
  final String typeFilter;
  final bool hideNsfw;
  final Future<void> Function() onToggleNsfw;
  final void Function(String type) onApply;

  const _FilterSheet({
    required this.typeFilter,
    required this.hideNsfw,
    required this.onToggleNsfw,
    required this.onApply,
  });

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late String _type;

  @override
  void initState() {
    super.initState();
    _type = widget.typeFilter;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    final accent = Theme.of(context).colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            'Lọc Extension',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Loại nguồn',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _TypeChip(
                label: 'Tất cả',
                value: 'all',
                selected: _type,
                accent: accent,
                textColor: textColor,
                onTap: (v) => setState(() => _type = v),
              ),
              _TypeChip(
                label: 'Truyện chữ',
                value: 'novel',
                selected: _type,
                accent: accent,
                textColor: textColor,
                onTap: (v) => setState(() => _type = v),
              ),
              _TypeChip(
                label: 'Manga/Comic',
                value: 'comic',
                selected: _type,
                accent: accent,
                textColor: textColor,
                onTap: (v) => setState(() => _type = v),
              ),
              _TypeChip(
                label: 'Tiếng Trung',
                value: 'chinese_novel',
                selected: _type,
                accent: accent,
                textColor: textColor,
                onTap: (v) => setState(() => _type = v),
              ),
              _TypeChip(
                label: 'TTS',
                value: 'tts',
                selected: _type,
                accent: accent,
                textColor: textColor,
                onTap: (v) => setState(() => _type = v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Nút ẩn/hiện 18+ với lời giải thích rõ ràng
          InkWell(
            onTap: widget.onToggleNsfw,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: widget.hideNsfw
                    ? Colors.grey.withValues(alpha: 0.08)
                    : Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: widget.hideNsfw
                      ? Colors.grey.withValues(alpha: 0.3)
                      : Colors.red.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.hideNsfw ? Icons.visibility_off : Icons.visibility,
                    color: widget.hideNsfw ? Colors.grey : Colors.red,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.hideNsfw
                              ? 'Đang ẩn nội dung 18+'
                              : 'Đang hiện nội dung 18+',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: widget.hideNsfw ? textColor : Colors.red,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.hideNsfw
                              ? 'Nhấn để hiện — cần xác nhận tuổi 18+'
                              : 'Nhấn để ẩn lại nội dung người lớn',
                          style: TextStyle(
                            fontSize: 12,
                            color: textColor.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: !widget.hideNsfw,
                    onChanged: (_) => widget.onToggleNsfw(),
                    activeThumbColor: Colors.red,
                    activeTrackColor: Colors.red.withValues(alpha: 0.4),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => widget.onApply(_type),
              child: const Text('Áp dụng'),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final String value;
  final String selected;
  final Color accent;
  final Color textColor;
  final void Function(String) onTap;

  const _TypeChip({
    required this.label,
    required this.value,
    required this.selected,
    required this.accent,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == value;
    return GestureDetector(
      onTap: () => onTap(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? accent : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? accent : textColor.withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: isSelected ? Colors.white : textColor,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ── Registry Manager Bottom Sheet ──
class _RegistryManagerSheet extends StatefulWidget {
  final VoidCallback onChanged;
  const _RegistryManagerSheet({required this.onChanged});

  @override
  State<_RegistryManagerSheet> createState() => _RegistryManagerSheetState();
}

class _RegistryManagerSheetState extends State<_RegistryManagerSheet> {
  List<String> _registries = [];
  bool _loading = true;

  static const _builtinLabels = {
    'https://raw.githubusercontent.com/dat-bi/ext-vbook/main/plugin.json':
        'dat-bi (Mặc định)',
    'https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/plugin.json':
        'Darkrai9x (Hako & các nguồn VN)',
  };

  @override
  void initState() {
    super.initState();
    _loadRegistries();
  }

  Future<void> _loadRegistries() async {
    final list = await ExtensionService.getRegistryUrls();
    setState(() {
      _registries = list;
      _loading = false;
    });
  }

  Future<void> _addRegistry() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Thêm Kho Extension'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'https://raw.githubusercontent.com/.../plugin.json',
            border: OutlineInputBorder(),
            labelText: 'URL registry (plugin.json)',
          ),
          autofocus: true,
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Thêm'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    if (!mounted) return;

    final validation = await confirmUserProvidedExtensionUrl(
      context,
      url,
      actionLabel: 'Tiep tuc them',
    );
    if (!mounted || validation == null) return;

    await ExtensionService.addRegistryUrl(validation.url);
    await _loadRegistries();
  }

  Future<void> _removeRegistry(String url) async {
    await ExtensionService.removeRegistryUrl(url);
    await _loadRegistries();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subColor = isDark ? Colors.grey.shade400 : Colors.grey.shade600;
    final accent = Theme.of(context).colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Kho Extension',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.add_link, color: accent),
                tooltip: 'Thêm kho mới',
                onPressed: _addRegistry,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Kho tích hợp sẵn không thể xóa',
            style: TextStyle(fontSize: 12, color: subColor),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _registries.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final url = _registries[index];
                final isBuiltin = _builtinLabels.containsKey(url);
                final label =
                    _builtinLabels[url] ??
                    Uri.tryParse(url)?.pathSegments
                        .where((s) => s.isNotEmpty)
                        .take(2)
                        .join('/') ??
                    url;

                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: isBuiltin
                          ? accent.withValues(alpha: 0.12)
                          : Colors.grey.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      isBuiltin ? Icons.verified : Icons.extension,
                      size: 18,
                      color: isBuiltin ? accent : Colors.grey,
                    ),
                  ),
                  title: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  subtitle: Text(
                    url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: subColor),
                  ),
                  trailing: isBuiltin
                      ? Tooltip(
                          message: 'Registry tích hợp sẵn',
                          child: Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: subColor,
                          ),
                        )
                      : IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                          tooltip: 'Xóa kho',
                          onPressed: () => _removeRegistry(url),
                        ),
                );
              },
            ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: widget.onChanged,
              icon: const Icon(Icons.refresh),
              label: const Text('Làm mới danh sách Extension'),
            ),
          ),
        ],
      ),
    );
  }
}
