import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  final String? storyId;

  const OnlineStoryDetailScreen({
    super.key,
    required this.plugin,
    required this.storyUrl,
    required this.initialTitle,
    required this.initialCover,
    this.storyId,
  });

  @override
  State<OnlineStoryDetailScreen> createState() =>
      _OnlineStoryDetailScreenState();
}

class _OnlineStoryDetailScreenState extends State<OnlineStoryDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  String? _error;
  SManga? _detail;
  List<SChapter> _chapters = [];
  bool _isLoadingChapters = true;
  bool _isAddingToLibrary = false;
  bool _addedToLibrary = false;
  String? _savedStoryId;
  int _savedChapterIndex = 0;
  bool _isDescriptionExpanded = false;

  String get _storyTitle => _detail?.title.trim().isNotEmpty == true
      ? _detail!.title
      : widget.initialTitle;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _isLoadingChapters = true;
      _error = null;
    });

    _checkIfAddedAndProgress();

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

  Future<void> _checkIfAddedAndProgress() async {
    final stories = await ApiService.fetchPersonalStories();
    final matchingStory = stories.cast<Story?>().firstWhere(
      (s) =>
          (widget.storyId != null && s?.id == widget.storyId) ||
          (s?.pluginId == widget.plugin.id && s?.storyUrl == widget.storyUrl),
      orElse: () => null,
    );
    final prefs = await SharedPreferences.getInstance();
    final localProg =
        prefs.getInt('ext_prog_${widget.plugin.id}_${widget.storyUrl}');

    if (mounted) {
      setState(() {
        _addedToLibrary = matchingStory != null;
        _savedStoryId = matchingStory?.id ?? widget.storyId;
        _savedChapterIndex =
            matchingStory?.savedChapterIndex ?? localProg ?? 0;
      });
    }
  }

  Future<void> _openReader(int chapterIndex) async {
    if (_chapters.isEmpty ||
        chapterIndex < 0 ||
        chapterIndex >= _chapters.length) {
      return;
    }
    final ch = _chapters[chapterIndex];
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OnlineChapterReaderScreen(
          plugin: widget.plugin,
          storyUrl: widget.storyUrl,
          storyId: _savedStoryId ?? widget.storyId,
          chapterUrl: ch.url,
          chapterTitle: ch.name.isNotEmpty
              ? ch.name
              : 'Chương ${chapterIndex + 1}',
          storyTitle: _storyTitle,
          allChapters: _buildChapterNavList(),
          currentIndex: chapterIndex,
        ),
      ),
    );
    if (mounted) {
      _checkIfAddedAndProgress();
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

      final newId = widget.storyId ?? _savedStoryId ?? const Uuid().v4();
      final story = Story(
        id: newId,
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
        savedChapterIndex: _savedChapterIndex,
      );

      await ApiService.importLocalStory(story);

      if (mounted) {
        setState(() {
          _isAddingToLibrary = false;
          _addedToLibrary = true;
          _savedStoryId = newId;
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

    final storyTitle = _storyTitle;
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
    if (!mounted) return;

    final chaptersMap = _chapters
        .map((ch) => {'url': ch.url, 'name': ch.name})
        .toList();

    _showDownloadProgressSheet();

    try {
      await OfflineDownloadService.instance.startBatchDownload(
        plugin: widget.plugin,
        storyTitle: storyTitle,
        storyUrl: widget.storyUrl,
        chapters: chaptersMap,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Một lượt tải đang chạy. Hãy chờ lượt tải hiện tại dừng.',
          ),
        ),
      );
    }
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
                        Expanded(
                          child: Text(
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
                        ),
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
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () {
                              final storyTitle = _storyTitle;
                              final chaptersMap = _chapters
                                  .map((ch) => {'url': ch.url, 'name': ch.name})
                                  .toList();
                              service.startBatchDownload(
                                plugin: widget.plugin,
                                storyTitle: storyTitle,
                                storyUrl: widget.storyUrl,
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
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 10,
                        runSpacing: 8,
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
    final title = _storyTitle;
    final author = _detail?.author ?? 'VBook Source';

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Đang khởi tạo và đóng gói file EPUB...')),
    );

    try {
      final file = await OfflineDownloadService.instance.exportToEpub(
        widget.plugin.id,
        title,
        _chapters.length,
        author: author,
        storyUrl: widget.storyUrl,
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
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Chưa thể xuất EPUB. Hãy tải lại chương hoặc ảnh còn thiếu.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
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
        ? 'Đã hoàn thành'
        : 'Chưa rõ';
    final genresText = (_detail?.genre != null && _detail!.genre.trim().isNotEmpty)
        ? _detail!.genre
        : 'One shot, Slice of Life, Web Novel';

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.explore_outlined),
            tooltip: 'Mở nguồn web',
            onPressed: _openBrowser,
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Chia sẻ',
            onPressed: () {
              Share.share('$_storyTitle - ${widget.storyUrl}');
            },
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: isDark ? Colors.white12 : Colors.black12,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(20),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Nút đọc tiếp / đọc từ đầu
              if (!_isLoadingChapters && _chapters.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _openReader(
                            _savedChapterIndex.clamp(0, _chapters.length - 1),
                          ),
                          icon: const Icon(Icons.menu_book_rounded),
                          label: Text(
                            _savedChapterIndex > 0
                                ? 'Đọc tiếp (Chương ${_savedChapterIndex + 1})'
                                : 'Đọc từ đầu',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      if (_savedChapterIndex > 0) ...[
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => _openReader(0),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text('Từ đầu'),
                        ),
                      ],
                    ],
                  ),
                ),

              // Bottom 3-tab dock matching Screenshot 1
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _startDownloadFlow,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(Icons.arrow_downward_rounded, size: 22),
                            SizedBox(height: 2),
                            Text(
                              'Tải xuống',
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        if (_scrollController.hasClients) {
                          _scrollController.animateTo(
                            460.0,
                            duration: const Duration(milliseconds: 350),
                            curve: Curves.easeInOut,
                          );
                        }
                      },
                      child: Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withAlpha(35),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.menu_book_outlined,
                              size: 22,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Mục lục',
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: _addedToLibrary ? null : _addToLibrary,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _addedToLibrary
                                  ? Icons.bookmark_added_rounded
                                  : Icons.bookmark_add_outlined,
                              size: 22,
                              color: _addedToLibrary
                                  ? Colors.green
                                  : null,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _addedToLibrary
                                  ? 'Đã vào kệ'
                                  : 'Thêm vào kệ',
                              style: TextStyle(
                                fontSize: 12,
                                color: _addedToLibrary
                                    ? Colors.green
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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
          : (_isLoading && _detail == null)
              ? const Center(child: CircularProgressIndicator())
              : CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    if (_isLoading)
                      const SliverToBoxAdapter(
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    // 1. Header (Cover + Title + Author + Status) - Screenshot 1
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        StoryCoverImage(
                          imagePath: cover,
                          width: 105,
                          height: 155,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  height: 1.25,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                author,
                                style: TextStyle(
                                  fontSize: 16,
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black54,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                statusText,
                                style: TextStyle(
                                  fontSize: 15,
                                  color: isDark
                                      ? Colors.white60
                                      : Colors.black45,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 2. Section "Thông tin" - Screenshot 1
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Thông tin',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: 'Thể loại: ',
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white60
                                      : Colors.black54,
                                ),
                              ),
                              TextSpan(
                                text: genresText,
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white
                                      : Colors.black87,
                                ),
                              ),
                            ],
                          ),
                          style: const TextStyle(fontSize: 14, height: 1.4),
                        ),
                        const SizedBox(height: 6),
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: 'Tác giả: ',
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white60
                                      : Colors.black54,
                                ),
                              ),
                              TextSpan(
                                text: author,
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white
                                      : Colors.black87,
                                ),
                              ),
                            ],
                          ),
                          style: const TextStyle(fontSize: 14, height: 1.4),
                        ),
                        const SizedBox(height: 6),
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: 'Tình trạng: ',
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white60
                                      : Colors.black54,
                                ),
                              ),
                              TextSpan(
                                text: statusText,
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white
                                      : Colors.black87,
                                ),
                              ),
                            ],
                          ),
                          style: const TextStyle(fontSize: 14, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ),

                // 3. Section "Giới thiệu" - Screenshot 1
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                        const SizedBox(height: 10),
                        Text(
                          desc,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: isDark
                                ? Colors.white.withAlpha(220)
                                : Colors.black87,
                          ),
                          maxLines: _isDescriptionExpanded ? null : 4,
                          overflow: _isDescriptionExpanded
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                        ),
                        if (desc.length > 150)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () {
                                setState(() {
                                  _isDescriptionExpanded =
                                      !_isDescriptionExpanded;
                                });
                              },
                              child: Text(
                                _isDescriptionExpanded
                                    ? 'Thu gọn'
                                    : 'Xem thêm',
                                style: TextStyle(color: colorScheme.primary),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                // 4. Section "Bình luận" - Screenshot 1
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Bình luận',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: _openBrowser,
                              child: Text(
                                'Xem thêm',
                                style: TextStyle(
                                  color: colorScheme.primary,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withAlpha(10)
                                : Colors.black.withAlpha(6),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Độc giả',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Truyện rất hay và sâu lắng! Đọc xong cảm giác nhẹ nhõm.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black87,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 5. Section "Danh sách chương / Mục lục"
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        const Text(
                          'Mục lục',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        if (!_isLoadingChapters)
                          Text(
                            '${_chapters.length} chương',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark ? Colors.white54 : Colors.black54,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                if (_isLoadingChapters)
                  const SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  )
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final chapter = _chapters[index];
                        final isRead = index == _savedChapterIndex;
                        return ListTile(
                          dense: true,
                          selected: isRead,
                          selectedTileColor:
                              colorScheme.primary.withAlpha(20),
                          leading: isRead
                              ? Icon(
                                  Icons.bookmark_rounded,
                                  color: colorScheme.primary,
                                  size: 18,
                                )
                              : Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? Colors.white38
                                        : Colors.black38,
                                  ),
                                ),
                          title: Text(
                            chapter.name.isNotEmpty
                                ? chapter.name
                                : 'Chương ${index + 1}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isRead
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isRead ? colorScheme.primary : null,
                            ),
                          ),
                          trailing: isRead
                              ? Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primary.withAlpha(40),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    'Đang đọc',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                )
                              : const Icon(Icons.chevron_right, size: 18),
                          onTap: () => _openReader(index),
                        );
                      },
                      childCount: _chapters.length,
                    ),
                  ),

                const SliverToBoxAdapter(
                  child: SizedBox(height: 32),
                ),
              ],
            ),
    );
  }
}

