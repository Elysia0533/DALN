import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../models/plugin_info.dart';
import '../services/offline_download_service.dart';
import 'online_chapter_reader_screen.dart';

class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({super.key});

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  String _storagePath = 'Đang kiểm tra...';
  List<Map<String, dynamic>> _downloadedStories = [];
  bool _isLoadingList = true;

  @override
  void initState() {
    super.initState();
    _loadStorageInfo();
  }

  Future<void> _loadStorageInfo() async {
    final path = await OfflineDownloadService.instance.publicStoragePath;
    final stories = await OfflineDownloadService.instance
        .getDownloadedStories();
    if (mounted) {
      setState(() {
        _storagePath = path;
        _downloadedStories = stories;
        _isLoadingList = false;
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
        listenable: OfflineDownloadService.instance,
        builder: (context, _) {
          final service = OfflineDownloadService.instance;
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
                                flex: 0,
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
              if (isError || service.failedCount > 0)
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
                                  'Có ${service.failedCount} chương bị lỗi khi tải về!',
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
                            'Nguồn truyện bị gián đoạn mạng hoặc phản hồi chậm. Bấm nút dưới đây để tải lại các chương lỗi.',
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
                              onPressed: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Bắt đầu tải lại các chương bị lỗi...',
                                    ),
                                  ),
                                );
                              },
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
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                              'Chưa có truyện nào được tải về',
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

                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => OnlineChapterReaderScreen(
                                    plugin: PluginInfo(
                                      id: pluginId,
                                      name: pluginId,
                                      version: 1,
                                      author: 'vBook',
                                      description: '',
                                      iconUrl: '',
                                      downloadUrl: '',
                                      locale: 'vi',
                                      source: '',
                                      type: 'novel',
                                    ),
                                    chapterUrl: navList.isNotEmpty
                                        ? navList.first.url
                                        : '',
                                    chapterTitle: navList.isNotEmpty
                                        ? navList.first.name
                                        : 'Chương 1',
                                    storyTitle: title,
                                    allChapters: navList,
                                    currentIndex: 0,
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
                                if (value == 'epub') {
                                  final file = await OfflineDownloadService
                                      .instance
                                      .exportToEpub(pluginId, title, count);
                                  if (file != null && mounted) {
                                    Share.shareXFiles([
                                      XFile(file.path),
                                    ], text: 'Truyện "$title" (File EPUB)');
                                  }
                                } else if (value == 'txt') {
                                  final file = await OfflineDownloadService
                                      .instance
                                      .exportToTxt(pluginId, title, count);
                                  if (file != null && mounted) {
                                    Share.shareXFiles([
                                      XFile(file.path),
                                    ], text: 'Truyện "$title" (File TXT)');
                                  }
                                } else if (value == 'delete') {
                                  await OfflineDownloadService.instance
                                      .deleteDownloadedStory(folderPath);
                                  _loadStorageInfo();
                                }
                              },
                              itemBuilder: (ctx) => [
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
