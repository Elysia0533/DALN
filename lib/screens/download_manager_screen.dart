import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as p;
import '../models/plugin_info.dart';
import '../services/offline_download_service.dart';
import 'online_chapter_reader_screen.dart';

class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({super.key, this.downloads});
  final OfflineDownloadService? downloads;

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  OfflineDownloadService get _service =>
      widget.downloads ?? OfflineDownloadService.instance;
  String _storagePath = 'Đang kiểm tra...';
  List<Map<String, dynamic>> _downloadedStories = [];
  bool _isLoadingList = true;
  String? _listError;
  int _listGeneration = 0;
  DownloadStatus? _observedStatus;

  @override
  void initState() {
    super.initState();
    _observedStatus = _service.status;
    _service.addListener(_onDownloadChanged);
    _loadStorageInfo();
  }

  @override
  void dispose() {
    _service.removeListener(_onDownloadChanged);
    super.dispose();
  }

  void _onDownloadChanged() {
    final status = _service.status;
    if (status == _observedStatus) return;
    _observedStatus = status;
    if (status != DownloadStatus.downloading) _loadStorageInfo();
  }

  PluginInfo _offlinePlugin(Map<String, dynamic> story) {
    final data = story['plugin'];
    if (data is Map) {
      try {
        return PluginInfo.fromJson(Map<String, dynamic>.from(data));
      } catch (_) {
        /* Legacy metadata can lack plugin fields. */
      }
    }
    final id = story['pluginId'] as String;
    return PluginInfo(
      id: id,
      name: id,
      version: 1,
      author: 'vBook',
      description: '',
      iconUrl: '',
      downloadUrl: '',
      locale: 'vi',
      source: '',
      type: story['type'] as String,
    );
  }

  Future<void> _loadStorageInfo() async {
    final generation = ++_listGeneration;
    try {
      final path = await _service.publicStoragePath;
      final stories = await _service.getDownloadedStories();
      if (mounted && generation == _listGeneration) {
        setState(() {
          _storagePath = path;
          _downloadedStories = stories;
          _isLoadingList = false;
          _listError = null;
        });
      }
    } catch (_) {
      if (!mounted || generation != _listGeneration) return;
      setState(() {
        _isLoadingList = false;
        _listError =
            'Không đọc được danh sách tải xuống. Hãy kiểm tra quyền lưu trữ rồi thử lại.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quản lý tải xuống'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Làm mới danh sách',
            onPressed: _loadStorageInfo,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final service = _service;
          final isDownloading = service.status == DownloadStatus.downloading;
          final isError = service.status == DownloadStatus.error;
          final progressPct = (service.progress * 100).toInt();

          return CustomScrollView(
            slivers: [
              // 1. Storage Location Information Header
              SliverToBoxAdapter(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_special_rounded,
                        color: colorScheme.primary,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Thư mục lưu offline trên máy',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _storagePath,
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 2. Active Downloading Status Card
              if (isDownloading)
                SliverToBoxAdapter(
                  child: Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    elevation: 2,
                    color: colorScheme.primaryContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  value: service.progress > 0
                                      ? service.progress
                                      : null,
                                  strokeWidth: 3,
                                  color: colorScheme.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Đang tải: ${service.storyTitle}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.stop_circle_outlined,
                                  color: Colors.red,
                                ),
                                tooltip: 'Dừng tải',
                                onPressed: () => service.cancelDownload(),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: service.progress,
                              minHeight: 8,
                              color: colorScheme.primary,
                              backgroundColor: colorScheme.onPrimaryContainer
                                  .withValues(alpha: 0.2),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Flexible(
                                flex: 1,
                                child: Text(
                                  '${service.downloadedCount}/${service.totalChapters} chương ($progressPct%)',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  service.currentDownloadingTitle,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                    color: colorScheme.onPrimaryContainer
                                        .withValues(alpha: 0.8),
                                  ),
                                  textAlign: TextAlign.end,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 3. Failed Chapters Warning & Re-download Button
              if (isError ||
                  service.failedCount > 0 ||
                  service.status == DownloadStatus.paused)
                SliverToBoxAdapter(
                  child: Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    color: colorScheme.errorContainer.withValues(alpha: 0.8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: Colors.red,
                                size: 28,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  service.status == DownloadStatus.paused
                                      ? 'Lượt tải đã dừng'
                                      : 'Còn chương hoặc ảnh chưa tải xong',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: colorScheme.onErrorContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            service.errorMessage.isNotEmpty
                                ? service.errorMessage
                                : 'Dữ liệu đã tải được giữ nguyên.',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onErrorContainer.withValues(
                                alpha: 0.9,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red.shade700,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: service.canRetry
                                  ? () async {
                                      await service.retryFailedDownloads();
                                      if (mounted) await _loadStorageInfo();
                                    }
                                  : null,
                              icon: const Icon(Icons.refresh),
                              label: Text(
                                'Tải lại ${service.failedCount > 0 ? "${service.failedCount} chương lỗi" : "chương thiếu"}',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 4. Downloaded Stories List Header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      const Text(
                        'Truyện đã lưu ngoại tuyến',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        '${_downloadedStories.length} bộ truyện',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 5. Downloaded Stories List
              _isLoadingList
                  ? const SliverFillRemaining(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _downloadedStories.isEmpty
                  ? SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.cloud_download_outlined,
                              size: 64,
                              color: colorScheme.outline,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _listError ?? 'Chưa có truyện nào được tải về',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                color: colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final story = _downloadedStories[index];
                        final title = story['storyTitle'] as String;
                        final pluginId = story['pluginId'] as String;
                        final count = story['chapterCount'] as int;
                        final folderPath = story['folderPath'] as String;
                        final storyUrl = story['storyUrl'] as String?;
                        final total = story['totalChapters'] as int;

                        return Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          elevation: 0.5,
                          child: ListTile(
                            onTap: () {
                              final List<dynamic> chaps =
                                  story['chapters'] as List<dynamic>? ?? [];
                              final List<ChapterNav> navList = chaps
                                  .map(
                                    (c) => ChapterNav(
                                      url: c['url'] ?? '',
                                      name: c['name'] ?? '',
                                    ),
                                  )
                                  .toList();
                              final firstIndex =
                                  (story['firstChapterIndex'] as int).clamp(
                                    0,
                                    navList.isEmpty ? 0 : navList.length - 1,
                                  );

                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => OnlineChapterReaderScreen(
                                    downloads: _service,
                                    plugin: _offlinePlugin(story),
                                    chapterUrl: navList.isNotEmpty
                                        ? navList[firstIndex].url
                                        : '',
                                    chapterTitle: navList.isNotEmpty
                                        ? navList[firstIndex].name
                                        : 'Chương 1',
                                    storyTitle: title,
                                    storyUrl: storyUrl,
                                    allChapters: navList,
                                    currentIndex: firstIndex,
                                  ),
                                ),
                              );
                            },
                            leading: CircleAvatar(
                              backgroundColor: colorScheme.primaryContainer,
                              child: Icon(
                                Icons.book_rounded,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                            title: Text(
                              title,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              'Nguồn: $pluginId • $count chương đã lưu',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (value) async {
                                try {
                                  if (value == 'epub') {
                                    final file = await _service.exportToEpub(
                                      pluginId,
                                      title,
                                      total,
                                      storyUrl: storyUrl,
                                    );
                                    if (file == null) {
                                      throw StateError(
                                        'No downloaded chapters.',
                                      );
                                    }
                                    if (mounted) {
                                      await Share.shareXFiles([
                                        XFile(
                                          file.path,
                                          name: p.basename(file.path),
                                        ),
                                      ], text: 'Truyện "$title" (File EPUB)');
                                    }
                                  } else if (value == 'txt') {
                                    final file = await _service.exportToTxt(
                                      pluginId,
                                      title,
                                      total,
                                      storyUrl: storyUrl,
                                    );
                                    if (file == null) {
                                      throw StateError(
                                        'No downloaded chapters.',
                                      );
                                    }
                                    if (mounted) {
                                      await Share.shareXFiles([
                                        XFile(
                                          file.path,
                                          name: p.basename(file.path),
                                        ),
                                      ], text: 'Truyện "$title" (File TXT)');
                                    }
                                  } else if (value == 'resume') {
                                    final chapters = (story['chapters'] as List)
                                        .map(
                                          (entry) => Map<String, String>.from(
                                            entry as Map,
                                          ),
                                        )
                                        .toList();
                                    await _service.startBatchDownload(
                                      plugin: _offlinePlugin(story),
                                      storyTitle: title,
                                      storyUrl: storyUrl,
                                      chapters: chapters,
                                    );
                                  } else if (value == 'delete') {
                                    await _service.deleteDownloadedStory(
                                      folderPath,
                                    );
                                    _loadStorageInfo();
                                  }
                                } catch (_) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Không thể hoàn tất. Hãy kiểm tra lượt tải và tải lại chương hoặc ảnh còn thiếu.',
                                      ),
                                    ),
                                  );
                                }
                              },
                              itemBuilder: (ctx) => [
                                if (total > 0)
                                  const PopupMenuItem(
                                    value: 'resume',
                                    child: Row(
                                      children: [
                                        Icon(Icons.download_rounded, size: 18),
                                        SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            'Tải chương và ảnh còn thiếu',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                const PopupMenuItem(
                                  value: 'epub',
                                  child: Row(
                                    children: [
                                      Icon(Icons.import_export, size: 18),
                                      SizedBox(width: 8),
                                      Text('Xuất file EPUB'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'txt',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.description_outlined,
                                        size: 18,
                                      ),
                                      SizedBox(width: 8),
                                      Text('Xuất file TXT'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.delete_outline,
                                        color: Colors.red,
                                        size: 18,
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'Xóa bộ nhớ',
                                        style: TextStyle(color: Colors.red),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }, childCount: _downloadedStories.length),
                    ),
            ],
          );
        },
      ),
    );
  }
}
