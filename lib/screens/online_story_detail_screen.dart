import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:share_plus/share_plus.dart';
import '../models/plugin_info.dart';
import '../models/story.dart';
import '../services/plugin/vbook_engine_channel.dart';
import '../services/plugin/plugin_loader.dart';
import '../models/source_models.dart';
import '../services/api_service.dart';
import '../services/offline_download_service.dart';
import '../widgets/story_cover_image.dart';
import 'online_chapter_reader_screen.dart';
import 'web_browser_screen.dart';

class OnlineStoryDetailScreen extends StatefulWidget {
  final PluginInfo plugin;
  final String storyUrl;
  final String initialTitle;
  final String initialCover;

  const OnlineStoryDetailScreen({
    super.key,
    required this.plugin,
    required this.storyUrl,
    required this.initialTitle,
    required this.initialCover,
  });

  @override
  State<OnlineStoryDetailScreen> createState() =>
      _OnlineStoryDetailScreenState();
}

class _OnlineStoryDetailScreenState extends State<OnlineStoryDetailScreen> {
  bool _isLoading = true;
  String? _error;
  SManga? _detail;
  List<SChapter> _chapters = [];
  bool _isLoadingChapters = true;
  bool _isAddingToLibrary = false;
  bool _addedToLibrary = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _isLoadingChapters = true;
      _error = null;
    });

    _checkIfAdded();

    try {
      final dirPath = await PluginLoader.getPluginDir(widget.plugin.id);
      await VBookEngineChannel.loadSource(widget.plugin.id, dirPath);

      final detail = await VBookEngineChannel.getMangaDetails(
        widget.plugin.id,
        widget.storyUrl,
      );
      if (mounted) {
        setState(() {
          _detail = detail;
          _isLoading = false;
        });
      }

      final chapterData = await VBookEngineChannel.getChapterList(
        widget.plugin.id,
        widget.storyUrl,
      );
      if (mounted) {
        setState(() {
          _chapters = chapterData;
          _isLoadingChapters = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
          _isLoadingChapters = false;
        });
      }
    }
  }

  Future<void> _checkIfAdded() async {
    final stories = await ApiService.fetchPersonalStories();
    final exists = stories.any(
      (s) =>
          s.storyUrl == widget.storyUrl ||
          (s.pluginId == widget.plugin.id && s.title == widget.initialTitle),
    );
    if (mounted && exists) {
      setState(() => _addedToLibrary = true);
    }
  }

  Future<void> _addToLibrary() async {
    if (_isAddingToLibrary || _addedToLibrary) return;
    setState(() => _isAddingToLibrary = true);

    try {
      final title = (_detail?.title.trim().isNotEmpty == true)
          ? _detail!.title
          : widget.initialTitle;
      final cover = (_detail?.thumbnailUrl.trim().isNotEmpty == true)
          ? _detail!.thumbnailUrl
          : widget.initialCover;
      final author = (_detail?.author.trim().isNotEmpty == true)
          ? _detail!.author
          : '';
      final desc = (_detail?.description.trim().isNotEmpty == true)
          ? _detail!.description
          : '';
      final genres = (_detail?.genre ?? '')
          .split(',')
          .map((g) => g.trim())
          .where((g) => g.isNotEmpty)
          .toList();

      final story = Story(
        id: const Uuid().v4(),
        title: title,
        description: desc,
        author: author,
        genres: genres,
        totalChapters: _chapters.length,
        iconUrl: cover,
        fileType: widget.plugin.type == 'comic' ? 'comic' : 'novel',
        isLocal: false,
        pluginId: widget.plugin.id,
        storyUrl: widget.storyUrl,
      );

      await ApiService.importLocalStory(story);

      if (mounted) {
        setState(() {
          _isAddingToLibrary = false;
          _addedToLibrary = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã thêm "$title" vào kệ sách!'),
            backgroundColor: Colors.green.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isAddingToLibrary = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lỗi: ${e.toString().replaceFirst("Exception: ", "")}',
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _openBrowser() async {
    final baseUrl =
        widget.plugin.source.isNotEmpty &&
            widget.plugin.source.startsWith('http')
        ? widget.plugin.source
        : widget.storyUrl;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            WebBrowserScreen(initialUrl: baseUrl, title: widget.plugin.name),
      ),
    );
    if (mounted) {
      _loadData();
    }
  }

  List<ChapterNav> _buildChapterNavList() {
    return _chapters
        .map((ch) => ChapterNav(url: ch.url, name: ch.name))
        .toList();
  }

  Future<void> _startDownloadFlow() async {
    if (_chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chưa có danh sách chương để tải.')),
      );
      return;
    }

    final storyTitle = _detail?.title ?? widget.initialTitle;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tải truyện Offline'),
        content: Text(
          'Xác nhận tải toàn bộ ${_chapters.length} chương của "$storyTitle" về đọc ngoại tuyến?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Tải về ngay'),
          ),
        ],
      ),
    );

    if (result != true) return;

    final chaptersMap = _chapters
        .map((ch) => {'url': ch.url, 'name': ch.name})
        .toList();

    _showDownloadProgressSheet();

    await OfflineDownloadService.instance.startBatchDownload(
      plugin: widget.plugin,
      storyTitle: storyTitle,
      chapters: chaptersMap,
    );
  }

  void _showDownloadProgressSheet() {
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return ListenableBuilder(
          listenable: OfflineDownloadService.instance,
          builder: (context, _) {
            final service = OfflineDownloadService.instance;
            final isDone = service.status == DownloadStatus.completed;
            final isError = service.status == DownloadStatus.error;

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isDone
                              ? Icons.check_circle_rounded
                              : (isError
                                    ? Icons.error_rounded
                                    : Icons.downloading_rounded),
                          color: isDone
                              ? Colors.green
                              : (isError
                                    ? Colors.red
                                    : Theme.of(context).primaryColor),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          isDone
                              ? 'Tải hoàn tất!'
                              : (isError
                                    ? 'Lỗi khi tải'
                                    : 'Đang tải về offline...'),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        if (isDone || isError)
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (!isDone && !isError) ...[
                      LinearProgressIndicator(value: service.progress),
                      const SizedBox(height: 10),
                      Text(
                        '${service.downloadedCount} / ${service.totalChapters} chương (${(service.progress * 100).toStringAsFixed(1)}%)',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        service.currentDownloadingTitle,
                        style: const TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {
                            service.cancelDownload();
                            Navigator.pop(ctx);
                          },
                          child: const Text(
                            'Dừng tải',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ),
                    ],
                    if (isError) ...[
                      Text(
                        service.failedCount > 0
                            ? 'Đã hoàn tất nhưng có ${service.failedCount} chương bị lỗi do phản hồi từ nguồn.'
                            : 'Đã xảy ra lỗi kết nối với nguồn truyện.',
                        style: const TextStyle(fontSize: 13, color: Colors.red),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () {
                              final storyTitle =
                                  _detail?.title ?? widget.initialTitle;
                              final chaptersMap = _chapters
                                  .map((ch) => {'url': ch.url, 'name': ch.name})
                                  .toList();
                              service.startBatchDownload(
                                plugin: widget.plugin,
                                storyTitle: storyTitle,
                                chapters: chaptersMap,
                              );
                            },
                            icon: const Icon(Icons.refresh),
                            label: Text(
                              service.failedCount > 0
                                  ? 'Tải lại ${service.failedCount} chương lỗi'
                                  : 'Tải lại các chương thiếu',
                            ),
                          ),
                          const SizedBox(width: 10),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Đóng'),
                          ),
                        ],
                      ),
                    ],
                    if (isDone) ...[
                      const Text('Toàn bộ chương đã được lưu ngoại tuyến.'),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () {
                              Navigator.pop(ctx);
                              _exportEpubFlow();
                            },
                            icon: const Icon(Icons.import_export_rounded),
                            label: const Text('Xuất file EPUB'),
                          ),
                          const SizedBox(width: 10),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Đóng'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _exportEpubFlow() async {
    final title = _detail?.title ?? widget.initialTitle;
    final author = _detail?.author ?? 'VBook Source';

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Đang khởi tạo và đóng gói file EPUB...')),
    );

    final file = await OfflineDownloadService.instance.exportToEpub(
      widget.plugin.id,
      title,
      _chapters.length,
      author: author,
    );

    final exportedFile = file;
    final exportedFileExists =
        exportedFile != null && await exportedFile.exists();
    if (!mounted) return;

    if (exportedFile != null && exportedFileExists) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Đã xuất file EPUB: ${exportedFile.path.split('/').last}',
          ),
          backgroundColor: Colors.green.shade700,
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Chia sẻ / Lưu',
            textColor: Colors.white,
            onPressed: () {
              Share.shareXFiles([
                XFile(exportedFile.path),
              ], text: 'Truyện "$title" (Định dạng EPUB)');
            },
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Chưa có chương offline nào được tải. Vui lòng bấm Tải Offline trước khi xuất EPUB.',
          ),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = (_detail?.title.trim().isNotEmpty == true)
        ? _detail!.title
        : widget.initialTitle;
    final cover = (_detail?.thumbnailUrl.trim().isNotEmpty == true)
        ? _detail!.thumbnailUrl
        : widget.initialCover;
    final author = (_detail?.author.trim().isNotEmpty == true)
        ? _detail!.author
        : 'Đang cập nhật';
    final desc = (_detail?.description.trim().isNotEmpty == true)
        ? _detail!.description
        : 'Đang cập nhật...';
    final status = _detail?.status ?? SManga.unknown;
    final statusText = status == SManga.ongoing
        ? 'Đang tiến hành'
        : status == SManga.completed
        ? 'Hoàn thành'
        : 'Không rõ';

    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        actions: [
          if (!_isLoadingChapters && _chapters.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.download_for_offline_outlined),
              tooltip: 'Tải truyện Offline',
              onPressed: _startDownloadFlow,
            ),
          if (!_isLoadingChapters && _chapters.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.import_export_rounded),
              tooltip: 'Xuất file EPUB',
              onPressed: _exportEpubFlow,
            ),
          IconButton(
            icon: const Icon(Icons.open_in_browser_outlined),
            tooltip: 'Mở trình duyệt / Đăng nhập',
            onPressed: _openBrowser,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cloud_off_rounded,
                      size: 64,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Không tải được chi tiết truyện',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
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
                    const Text(
                      'Nguồn truyện có thể bị chặn địa lý, yêu cầu Cloudflare hoặc đăng nhập web.',
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _openBrowser,
                      icon: const Icon(Icons.open_in_browser),
                      label: const Text('Mở trình duyệt và đăng nhập'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _loadData,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Thử lại'),
                    ),
                  ],
                ),
              ),
            )
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        StoryCoverImage(
                          imagePath: cover,
                          width: 120,
                          height: 180,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Tác giả: $author',
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(
                                    status == SManga.completed
                                        ? Icons.check_circle_outline
                                        : Icons.schedule,
                                    size: 14,
                                    color: status == SManga.completed
                                        ? Colors.green
                                        : Colors.orange,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    statusText,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                              if (!_isLoadingChapters) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '${_chapters.length} chương',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              if (_isLoading) const CircularProgressIndicator(),
                              if (!_isLoading) ...[
                                // Nút thêm vào kệ sách
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    onPressed: _addedToLibrary
                                        ? null
                                        : _addToLibrary,
                                    icon: _isAddingToLibrary
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : Icon(
                                            _addedToLibrary
                                                ? Icons.check_rounded
                                                : Icons.library_add_outlined,
                                          ),
                                    label: Text(
                                      _addedToLibrary
                                          ? 'Đã thêm vào kệ sách'
                                          : 'Thêm vào kệ sách',
                                    ),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: _addedToLibrary
                                          ? Colors.grey
                                          : colorScheme.primary,
                                    ),
                                  ),
                                ),
                                if (_chapters.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                OnlineChapterReaderScreen(
                                                  plugin: widget.plugin,
                                                  chapterUrl:
                                                      _chapters.first.url,
                                                  chapterTitle:
                                                      _chapters
                                                          .first
                                                          .name
                                                          .isNotEmpty
                                                      ? _chapters.first.name
                                                      : 'Chương 1',
                                                  storyTitle:
                                                      _detail?.title ??
                                                      widget.initialTitle,
                                                  allChapters:
                                                      _buildChapterNavList(),
                                                  currentIndex: 0,
                                                ),
                                          ),
                                        );
                                      },
                                      icon: const Icon(
                                        Icons.play_arrow_rounded,
                                      ),
                                      label: const Text('Đọc từ đầu'),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          onPressed: _startDownloadFlow,
                                          icon: const Icon(
                                            Icons.download_rounded,
                                            size: 18,
                                          ),
                                          label: const Text(
                                            'Tải Offline',
                                            style: TextStyle(fontSize: 13),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          onPressed: _exportEpubFlow,
                                          icon: const Icon(
                                            Icons.import_export_rounded,
                                            size: 18,
                                          ),
                                          label: const Text(
                                            'Xuất EPUB',
                                            style: TextStyle(fontSize: 13),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Giới thiệu',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          desc,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            const Text(
                              'Danh sách chương',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            if (!_isLoadingChapters && _chapters.isNotEmpty)
                              Text(
                                '${_chapters.length} chương',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
                if (_isLoadingChapters)
                  const SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final chapter = _chapters[index];
                      return ListTile(
                        title: Text(
                          chapter.name.isNotEmpty
                              ? chapter.name
                              : 'Chương ${index + 1}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => OnlineChapterReaderScreen(
                                plugin: widget.plugin,
                                chapterUrl: chapter.url,
                                chapterTitle: chapter.name.isNotEmpty
                                    ? chapter.name
                                    : 'Chương ${index + 1}',
                                storyTitle:
                                    _detail?.title ?? widget.initialTitle,
                                allChapters: _buildChapterNavList(),
                                currentIndex: index,
                              ),
                            ),
                          );
                        },
                      );
                    }, childCount: _chapters.length),
                  ),
              ],
            ),
    );
  }
}
