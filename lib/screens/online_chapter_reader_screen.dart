import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/online_chapter_content.dart';
import '../widgets/chapter_image.dart';
import '../models/plugin_info.dart';
import '../services/plugin/vbook_engine_channel.dart';
import '../services/plugin/plugin_loader.dart';
import '../services/api_service.dart';
import '../theme/reading_settings_provider.dart';
import '../widgets/reader_selectable_text.dart';
import '../widgets/tts_control_sheet.dart';
import '../models/story.dart';
import '../services/tts_service.dart';
import '../services/offline_download_service.dart';
import '../services/han_viet_translator_service.dart';
import 'web_browser_screen.dart';
import '../features/translator_bot/ui/ellie_quick_translate_sheet.dart';
import '../features/translator_bot/ui/ellie_chat_screen.dart';

class OnlineChapterReaderScreen extends StatefulWidget {
  final PluginInfo plugin;
  final String chapterUrl;
  final String chapterTitle;
  final String storyTitle;
  final String? storyUrl;
  final String? storyId;
  final OfflineDownloadService? downloads;
  final List<ChapterNav>? allChapters;
  final int currentIndex;

  const OnlineChapterReaderScreen({
    super.key,
    required this.plugin,
    required this.chapterUrl,
    required this.chapterTitle,
    this.storyTitle = '',
    this.storyUrl,
    this.storyId,
    this.downloads,
    this.allChapters,
    this.currentIndex = 0,
  });

  @override
  State<OnlineChapterReaderScreen> createState() =>
      _OnlineChapterReaderScreenState();
}

class ChapterNav {
  final String url;
  final String name;
  const ChapterNav({required this.url, required this.name});
}

class _OnlineChapterReaderScreenState extends State<OnlineChapterReaderScreen>
    with WidgetsBindingObserver {
  late String _currentUrl;
  late String _currentTitle;
  late int _currentIndex;

  bool _isLoading = true;
  String? _error;
  List<ChapterBlock> _blocks = [];
  List<ChapterBlock>? _translatedSource;
  bool? _translatedEnabled;
  List<String> _displayBlocks = [];
  List<int> _displayOffsets = [];
  String _displayText = '';
  int _loadGeneration = 0;
  OfflineDownloadService get _downloads =>
      widget.downloads ?? OfflineDownloadService.instance;
  String get _bookTitle => widget.storyTitle.trim().isNotEmpty
      ? widget.storyTitle
      : widget.chapterTitle;
  String _content = '';
  bool _isComic = false;
  bool _showToolbars = true;

  bool get _hasPrevious => widget.allChapters != null && _currentIndex > 0;
  bool get _hasNext =>
      widget.allChapters != null &&
      _currentIndex < (widget.allChapters!.length - 1);

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _drawerScrollController = ScrollController();
  final TextEditingController _drawerSearchController = TextEditingController();
  final GlobalKey _bottomBarKey = GlobalKey();
  double _bottomBarHeight = 180;
  bool _isLandscape = false;
  bool _isTtsMode = false;
  double _scrollProgress = 0.0;

  double get _totalReadingPercent {
    final totalChapters = widget.allChapters?.length ?? 1;
    if (totalChapters <= 0) return 0.0;
    return (((_currentIndex + _scrollProgress) / totalChapters) * 100)
        .clamp(0.0, 100.0);
  }

  void _toggleToolbars() {
    setState(() => _showToolbars = !_showToolbars);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    final offset = _scrollController.offset;
    final double progress = max > 0 ? (offset / max).clamp(0.0, 1.0) : 0.0;
    if ((progress - _scrollProgress).abs() > 0.005) {
      setState(() {
        _scrollProgress = progress;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUrl = widget.chapterUrl;
    _currentTitle = widget.chapterTitle;
    _currentIndex = widget.currentIndex;
    _scrollController.addListener(_onScroll);
    _loadContent();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveReadingProgress();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _drawerScrollController.dispose();
    _drawerSearchController.dispose();
    _saveReadingProgress();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  void _toggleOrientation() {
    setState(() {
      _isLandscape = !_isLandscape;
    });
    if (_isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  Future<void> _saveReadingProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (widget.storyUrl != null && widget.storyUrl!.isNotEmpty) {
        await prefs.setInt(
          'ext_prog_${widget.plugin.id}_${widget.storyUrl}',
          _currentIndex,
        );
      }
      String? targetStoryId = widget.storyId;
      if (targetStoryId == null && widget.storyUrl != null && widget.storyUrl!.isNotEmpty) {
        final stories = await ApiService.fetchPersonalStories();
        final found = stories.cast<Story?>().firstWhere(
          (s) => s?.pluginId == widget.plugin.id && s?.storyUrl == widget.storyUrl,
          orElse: () => null,
        );
        if (found != null) targetStoryId = found.id;
      }
      if (targetStoryId != null) {
        await ApiService.saveChapterProgress(
          targetStoryId,
          _currentIndex,
          totalChapters: widget.allChapters?.length,
        );
      }
    } catch (_) {}
  }

  Future<void> _loadContent() async {
    final generation = ++_loadGeneration;
    final url = _currentUrl;
    final index = _currentIndex;
    setState(() {
      _isLoading = true;
      _error = null;
      _blocks = [];
      _content = '';
    });
    try {
      OnlineChapterContent? content;
      try {
        final stored = await _downloads.getDownloadedChapterContent(
          widget.plugin.id,
          _bookTitle,
          index,
          storyUrl: widget.storyUrl,
          chapterUrl: url,
          sourceType: widget.plugin.type,
        );
        if (stored != null) {
          content = OnlineChapterContent.decode(
            stored,
            chapterUrl: url,
            sourceType: widget.plugin.type,
          );
        }
      } catch (_) {
        // A damaged local chapter must not leave the reader stuck loading.
      }
      if (!mounted || generation != _loadGeneration) return;
      if (content == null) {
        final dirPath = await PluginLoader.getPluginDir(widget.plugin.id);
        final ready = await VBookEngineChannel.loadSource(
          widget.plugin.id,
          dirPath,
        );
        if (!mounted || generation != _loadGeneration) return;
        if (!ready) throw StateError('Source unavailable.');
        final pages = await VBookEngineChannel.getPageList(
          widget.plugin.id,
          url,
        );
        content = OnlineChapterContent.fromPages(
          pages,
          chapterUrl: url,
          sourceType: widget.plugin.type,
        );
      }
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _blocks = content!.blocks;
        _content = content.text;
        _isComic = content.isComic;
        _isLoading = false;
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      setState(() => _scrollProgress = 0.0);
      _saveReadingProgress();
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error =
            'Nguồn chưa trả nội dung hợp lệ. Hãy thử lại hoặc mở trang nguồn để kiểm tra đăng nhập.';
        _isLoading = false;
      });
    }
  }

  Future<void> _startDownload() async {
    try {
      final chapters =
          widget.allChapters
              ?.map((c) => {'url': c.url, 'name': c.name})
              .toList() ??
          [
            {'url': _currentUrl, 'name': _currentTitle},
          ];
      await _downloads.startBatchDownload(
        plugin: widget.plugin,
        storyTitle: _bookTitle,
        storyUrl: widget.storyUrl,
        chapters: chapters,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _downloads.status == DownloadStatus.completed
                ? 'Đã tải đủ chương và ảnh.'
                : _downloads.errorMessage.isNotEmpty
                ? _downloads.errorMessage
                : 'Đã dừng tải.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Chưa thể bắt đầu tải. Hãy kiểm tra lượt tải hiện tại.',
          ),
        ),
      );
    }
  }

  Future<void> _exportEpub() async {
    try {
      final file = await _downloads.exportToEpub(
        widget.plugin.id,
        _bookTitle,
        widget.allChapters?.length ?? 1,
        storyUrl: widget.storyUrl,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            file == null
                ? 'Hãy tải truyện trước khi xuất EPUB.'
                : 'Đã xuất EPUB theo tên truyện.',
          ),
        ),
      );
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

  Future<void> _openBrowser() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WebBrowserScreen(
          initialUrl: _currentUrl,
          title: widget.plugin.name,
        ),
      ),
    );
    if (mounted) {
      _loadContent();
    }
  }

  void _goToChapter(int index) {
    if (widget.allChapters == null ||
        index < 0 ||
        index >= widget.allChapters!.length) {
      return;
    }

    final chapter = widget.allChapters![index];
    setState(() {
      _currentIndex = index;
      _currentUrl = chapter.url;
      _currentTitle = chapter.name;
    });
    _saveReadingProgress();
    _loadContent().then((_) {
      if (mounted && (_isTtsMode || TtsService.instance.isPlaying)) {
        TtsService.instance.speak(
          _displayText.isNotEmpty ? _displayText : _content,
          onChapterComplete:
              _hasNext ? () => _goToChapter(_currentIndex + 1) : null,
          chapterIndex: _currentIndex,
        );
      }
    });
  }

  void _showChapterListModal() {
    if (widget.allChapters == null || widget.allChapters!.isEmpty) return;

    final searchController = TextEditingController();
    List<ChapterNav> filteredChapters = List.from(widget.allChapters!);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final theme = Theme.of(context);
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.withAlpha(100),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.list_alt_rounded),
                        const SizedBox(width: 8),
                        Text(
                          'Mục lục (${widget.allChapters!.length} chương)',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        hintText: 'Tìm kiếm chương...',
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest
                            .withAlpha(120),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (val) {
                        setModalState(() {
                          filteredChapters = widget.allChapters!
                              .where(
                                (c) => c.name.toLowerCase().contains(
                                  val.toLowerCase(),
                                ),
                              )
                              .toList();
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filteredChapters.length,
                      itemBuilder: (context, idx) {
                        final ch = filteredChapters[idx];
                        final isCurrent = ch.url == _currentUrl;
                        final originalIndex = widget.allChapters!.indexOf(ch);

                        return ListTile(
                          selected: isCurrent,
                          selectedTileColor: theme.colorScheme.primaryContainer
                              .withAlpha(80),
                          dense: true,
                          title: Text(
                            ch.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isCurrent
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isCurrent
                                  ? theme.colorScheme.primary
                                  : null,
                            ),
                          ),
                          trailing: isCurrent
                              ? Icon(
                                  Icons.check_circle,
                                  color: theme.colorScheme.primary,
                                  size: 18,
                                )
                              : null,
                          onTap: () {
                            Navigator.pop(context);
                            _goToChapter(originalIndex);
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

  void _showSettingsModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final settings = context.watch<ReadingSettingsProvider>();
        final theme = Theme.of(context);

        return Container(
          decoration: BoxDecoration(
            color: settings.bgColor == const Color(0xFF000000)
                ? const Color(0xFF1E1E1E)
                : theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.withAlpha(100),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Tùy chỉnh đọc',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),

              // Font Size Slider
              Row(
                children: [
                  const Text(
                    'A-',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  Expanded(
                    child: Slider(
                      value: settings.fontSize,
                      min: 12.0,
                      max: 30.0,
                      divisions: 18,
                      label: '${settings.fontSize.round()}px',
                      onChanged: (v) => settings.setFontSize(v),
                    ),
                  ),
                  const Text(
                    'A+',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Theme Selector
              Text(
                'Màu nền giao diện:',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: ReadingSettingsProvider.bgColors.map((c) {
                  final colorVal = c['value'] as int;
                  final isSelected = settings.bgColor.toARGB32() == colorVal;
                  return GestureDetector(
                    onTap: () => settings.setBgColor(colorVal),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Color(colorVal),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : Colors.grey.shade400,
                          width: isSelected ? 3 : 1,
                        ),
                        boxShadow: [
                          if (isSelected)
                            BoxShadow(
                              color: theme.colorScheme.primary.withAlpha(100),
                              blurRadius: 8,
                            ),
                        ],
                      ),
                      child: isSelected
                          ? Icon(
                              Icons.check,
                              size: 20,
                              color: Color(c['textColor'] as int),
                            )
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // Font Family Selector
              Text(
                'Phông chữ:',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: ReadingSettingsProvider.availableFonts.map((f) {
                    final isSelected = settings.fontFamily == f['name'];
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(f['label']!),
                        selected: isSelected,
                        onSelected: (_) => settings.setFontFamily(f['name']!),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),

              // Line Height Slider
              Row(
                children: [
                  Text(
                    'Khoảng cách dòng: ${settings.lineHeight.toStringAsFixed(1)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Expanded(
                    child: Slider(
                      value: settings.lineHeight,
                      min: 1.2,
                      max: 2.2,
                      divisions: 10,
                      onChanged: (v) => settings.setLineHeight(v),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBlock(int index, ReadingSettingsProvider settings) {
    final block = _blocks[index];
    if (block.isImage) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleToolbars,
        child: ChapterImage(block: block, referer: _currentUrl),
      );
    }
    final offset = _displayOffsets[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ReaderSelectableText(
        _displayBlocks[index],
        style: settings.bodyTextStyle,
        onTap: _toggleToolbars,
        onSelectionSpeak: (selectedText, start, end) {
          TtsService.instance.speakFromSelection(
            fullText: _displayText,
            selectedText: selectedText,
            selectionStart: offset + start,
            selectionEnd: offset + end,
            onChapterComplete: _hasNext
                ? () => _goToChapter(_currentIndex + 1)
                : null,
          );
        },
        onTranslate: (selectedText) {
          if (selectedText.trim().isEmpty) return;
          EllieQuickTranslateSheet.show(
            context,
            selectedText.trim(),
            title: _currentTitle,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ReadingSettingsProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final translator = HanVietTranslatorService.instance;
    if (!identical(_translatedSource, _blocks) ||
        _translatedEnabled != translator.enabled) {
      _translatedSource = _blocks;
      _translatedEnabled = translator.enabled;
      _displayBlocks = [];
      _displayOffsets = [];
      final texts = <String>[];
      var offset = 0;
      for (final block in _blocks) {
        final text = block.isImage ? '' : translator.translate(block.value);
        _displayBlocks.add(text);
        _displayOffsets.add(offset);
        if (!block.isImage) {
          texts.add(text);
          offset += text.length + 2;
        }
      }
      _displayText = texts.join('\n\n');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _bottomBarKey.currentContext?.findRenderObject();
      if (box is RenderBox &&
          box.hasSize &&
          (box.size.height - _bottomBarHeight).abs() > 0.5) {
        setState(() => _bottomBarHeight = box.size.height);
      }
    });

    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        _saveReadingProgress();
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _buildChapterDrawer(context, settings),
        drawerEdgeDragWidth: 40,
        backgroundColor: settings.bgColor,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleToolbars,
        child: Stack(
          children: [
            // Body Content (Full screen reader)
            Positioned.fill(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.cloud_off_rounded,
                              size: 64,
                              color: Colors.grey,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Không tải được nội dung chương',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: settings.textColor,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              style: TextStyle(
                                fontSize: 12,
                                color: settings.textColor.withAlpha(150),
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: _openBrowser,
                              icon: const Icon(Icons.open_in_browser),
                              label: const Text('Mở trình duyệt & Đăng nhập'),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _loadContent,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Thử lại'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _isComic
                  ? GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _toggleToolbars,
                      child: InteractiveViewer(
                        minScale: 1.0,
                        maxScale: 3.5,
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.only(
                            top: 64,
                            bottom: _bottomBarHeight + 24,
                          ),
                          itemCount: _blocks.length,
                          itemBuilder: (context, index) {
                            return _buildBlock(index, settings);
                          },
                        ),
                      ),
                    )
                  : GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _toggleToolbars,
                      child: ListView.builder(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(
                          20,
                          72,
                          20,
                          _bottomBarHeight + 24,
                        ),
                        itemCount: _blocks.length + 2,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Center(
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 780),
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    top: 16,
                                    bottom: 20,
                                  ),
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onTap: _toggleToolbars,
                                    child: Text(
                                      _currentTitle,
                                      style: settings.bodyTextStyle.copyWith(
                                        fontSize: settings.fontSize + 6,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }
                          if (index <= _blocks.length) {
                            return Center(
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 780),
                                child: _buildBlock(index - 1, settings),
                              ),
                            );
                          }
                          // End of Chapter indicator
                          return Center(
                            child: ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxWidth: 780),
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  top: 60,
                                  bottom: 40,
                                ),
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.check_circle_outline_rounded,
                                      color: settings.textColor.withAlpha(120),
                                      size: 36,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Hết $_currentTitle',
                                      style: TextStyle(
                                        color: settings.textColor.withAlpha(
                                          150,
                                        ),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    if (_hasNext)
                                      ElevatedButton.icon(
                                        onPressed: () =>
                                            _goToChapter(_currentIndex + 1),
                                        icon: const Icon(Icons.arrow_forward),
                                        label: const Text(
                                          'Đọc chương tiếp theo',
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),

            // Top Overlay Bar (Animates in/out)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 250),
                offset: _showToolbars ? Offset.zero : const Offset(0, -1),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  opacity: _showToolbars ? 1 : 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: settings.bgColor.withValues(alpha: 0.98),
                      border: Border(
                        bottom: BorderSide(
                          color: settings.textColor.withValues(alpha: 0.08),
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                Icons.arrow_back_ios_new,
                                color: settings.textColor,
                                size: 20,
                              ),
                              onPressed: () => Navigator.pop(context),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _currentTitle,
                                    style: settings.bodyTextStyle.copyWith(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    widget.plugin.name,
                                    style: TextStyle(
                                      color: settings.textColor.withAlpha(140),
                                      fontSize: 11,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),

                            // Quick Action Menu Buttons
                            if (!_isComic) ...[
                              IconButton(
                                icon: Icon(
                                  Icons.volume_up_rounded,
                                  color: settings.textColor,
                                ),
                                tooltip: 'Đọc tự động (TTS)',
                                onPressed: () {
                                  TtsControlSheet.show(
                                    context,
                                    textContent: _content,
                                    onNextChapter: _hasNext
                                        ? () => _goToChapter(_currentIndex + 1)
                                        : null,
                                  );
                                },
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.format_list_bulleted_rounded,
                                  color: settings.textColor,
                                ),
                                tooltip: 'Mục lục chương',
                                onPressed: _showChapterListModal,
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.tune_rounded,
                                  color: settings.textColor,
                                ),
                                tooltip: 'Tùy chỉnh giao diện',
                                onPressed: _showSettingsModal,
                              ),
                            ],
                            IconButton(
                              icon: Icon(
                                Icons.open_in_browser_outlined,
                                color: settings.textColor,
                              ),
                              tooltip: 'Mở web / Đăng nhập',
                              onPressed: _openBrowser,
                            ),
                            PopupMenuButton<String>(
                              icon: Icon(
                                Icons.more_vert_rounded,
                                color: settings.textColor,
                              ),
                              tooltip: 'Tùy chọn khác',
                              onSelected: (val) {
                                if (val == 'download') {
                                  _startDownload();
                                } else if (val == 'epub') {
                                  _exportEpub();
                                } else if (val == 'hanviet') {
                                  setState(() {
                                    HanVietTranslatorService.instance
                                        .toggleTranslator();
                                  });
                                } else if (val == 'ellie') {
                                  final text = _displayBlocks.join('\n\n');
                                  if (text.trim().isNotEmpty) {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => EllieChatScreen(
                                          initialText: text,
                                          initialTitle: _currentTitle,
                                        ),
                                      ),
                                    );
                                  }
                                }
                              },
                              itemBuilder: (ctx) => [
                                PopupMenuItem(
                                  value: 'download',
                                  child: Row(
                                    children: const [
                                      Icon(Icons.download_rounded, size: 18),
                                      SizedBox(width: 8),
                                      Text('Tải truyện Offline'),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'epub',
                                  child: Row(
                                    children: const [
                                      Icon(Icons.menu_book_outlined, size: 18),
                                      SizedBox(width: 8),
                                      Text('Xuất EPUB'),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'hanviet',
                                  child: Row(
                                    children: [
                                      const Icon(Icons.g_translate_rounded, size: 18),
                                      const SizedBox(width: 8),
                                      Text(
                                        HanVietTranslatorService.instance.enabled
                                            ? 'Tắt Hán-Việt'
                                            : 'Bật Hán-Việt',
                                      ),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'ellie',
                                  child: Row(
                                    children: [
                                      Icon(Icons.auto_awesome_rounded, color: Colors.pinkAccent, size: 18),
                                      SizedBox(width: 8),
                                      Text('Dịch chương với Ellie 🌸'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Floating unobtrusive reading progress indicator when toolbars are hidden
            Positioned(
              bottom: 10,
              right: 14,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _showToolbars ? 0.0 : 0.75,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: settings.bgColor.withAlpha(210),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: settings.textColor.withAlpha(35),
                        width: 0.8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(30),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: Text(
                      '${_currentIndex + 1}/${widget.allChapters?.length ?? 1} • ${_totalReadingPercent.toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: settings.textColor.withAlpha(200),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Bottom Overlay Bar (Animates in/out)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 250),
                offset: _showToolbars ? Offset.zero : const Offset(0, 1),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  opacity: _showToolbars ? 1 : 0,
                  child: Container(
                    key: _bottomBarKey,
                    decoration: BoxDecoration(
                      color: settings.bgColor.withValues(alpha: 0.98),
                      border: Border(
                        top: BorderSide(
                          color: settings.textColor.withValues(alpha: 0.08),
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.10),
                          blurRadius: 14,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: SafeArea(
                      child: _isTtsMode || TtsService.instance.isPlaying
                          ? _buildTtsBottomBar(settings, colorScheme)
                          : _buildNormalBottomBar(settings, colorScheme),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  }

  Widget _buildNormalBottomBar(
    ReadingSettingsProvider settings,
    ColorScheme colorScheme,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.allChapters != null && widget.allChapters!.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Chương ${_currentIndex + 1}/${widget.allChapters!.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: settings.textColor.withAlpha(180),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withAlpha(25),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: colorScheme.primary.withAlpha(50),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    '${_totalReadingPercent.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
            child: Row(
              children: [
                Text(
                  '1',
                  style: TextStyle(
                    fontSize: 11,
                    color: settings.textColor.withAlpha(150),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _currentIndex.toDouble().clamp(
                      0.0,
                      (widget.allChapters!.length - 1).toDouble(),
                    ),
                    min: 0.0,
                    max: (widget.allChapters!.length - 1).toDouble(),
                    divisions: widget.allChapters!.length > 1
                        ? widget.allChapters!.length - 1
                        : 1,
                    onChanged: (val) {
                      _goToChapter(val.round());
                    },
                  ),
                ),
                Text(
                  '${widget.allChapters!.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: settings.textColor.withAlpha(150),
                  ),
                ),
              ],
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              // Icon 1: Mục lục (80% left drawer)
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.format_list_bulleted_rounded),
                tooltip: 'Mục lục chương (Mở từ trái)',
                color: settings.textColor,
                onPressed: () {
                  _scaffoldKey.currentState?.openDrawer();
                },
              ),
              // Icon 2: Rotation xoay màn hình
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: Icon(
                  _isLandscape
                      ? Icons.stay_current_portrait_rounded
                      : Icons.screen_rotation_rounded,
                ),
                tooltip: _isLandscape ? 'Xoay lại dọc' : 'Xoay ngang màn hình',
                color: _isLandscape ? colorScheme.primary : settings.textColor,
                onPressed: _toggleOrientation,
              ),
              // Icon 3: Audio TTS chuyển sang thanh công cụ TTS
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.headphones_rounded),
                tooltip: 'Nghe đọc TTS',
                color: settings.textColor,
                onPressed: () {
                  setState(() => _isTtsMode = true);
                  if (!TtsService.instance.isPlaying) {
                    TtsService.instance.speak(
                      _displayText.isNotEmpty ? _displayText : _content,
                      onChapterComplete: _hasNext
                          ? () => _goToChapter(_currentIndex + 1)
                          : null,
                      chapterIndex: _currentIndex,
                    );
                  }
                },
              ),
              // Chương trước
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.chevron_left_rounded),
                tooltip: 'Chương trước',
                color: settings.textColor,
                onPressed:
                    _hasPrevious ? () => _goToChapter(_currentIndex - 1) : null,
              ),
              // Chương sau
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.chevron_right_rounded),
                tooltip: 'Chương sau',
                color: settings.textColor,
                onPressed:
                    _hasNext ? () => _goToChapter(_currentIndex + 1) : null,
              ),
              // Cài đặt đọc
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.tune_rounded),
                tooltip: 'Tùy chỉnh giao diện',
                color: settings.textColor,
                onPressed: _showSettingsModal,
              ),
              // Mở web
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.open_in_browser_rounded),
                tooltip: 'Mở nguồn web',
                color: settings.textColor,
                onPressed: _openBrowser,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTtsBottomBar(
    ReadingSettingsProvider settings,
    ColorScheme colorScheme,
  ) {
    final tts = TtsService.instance;
    return ListenableBuilder(
      listenable: tts,
      builder: (context, _) {
        final timerLeft = tts.timerMinutesRemaining;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
              child: Row(
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 16,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Đang đọc TTS: $_currentTitle',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: settings.textColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withAlpha(25),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${_totalReadingPercent.toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                  if (timerLeft > 0 || tts.stopAtEndOfChapter)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.withAlpha(35),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.timer_outlined,
                            size: 12,
                            color: Colors.green,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            tts.stopAtEndOfChapter
                                ? 'Hết ch.'
                                : '${timerLeft}p',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  // Previous paragraph / chapter
                  IconButton(
                    icon: const Icon(Icons.skip_previous_rounded),
                    tooltip: 'Đoạn trước',
                    color: settings.textColor,
                    onPressed: () {
                      if (tts.currentParagraphIndex > 0) {
                        tts.previousParagraph();
                      } else if (_hasPrevious) {
                        _goToChapter(_currentIndex - 1);
                      }
                    },
                  ),
                  // Start / Stop (Play/Pause)
                  IconButton(
                    iconSize: 34,
                    icon: Icon(
                      tts.isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_filled_rounded,
                    ),
                    tooltip: tts.isPlaying ? 'Tạm dừng' : 'Tiếp tục đọc',
                    color: colorScheme.primary,
                    onPressed: () {
                      if (tts.isPlaying) {
                        tts.pause();
                      } else if (tts.isPaused) {
                        tts.resume();
                      } else {
                        tts.speak(
                          _displayText.isNotEmpty ? _displayText : _content,
                          onChapterComplete: _hasNext
                              ? () => _goToChapter(_currentIndex + 1)
                              : null,
                          chapterIndex: _currentIndex,
                        );
                      }
                    },
                  ),
                  // Next paragraph / chapter
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded),
                    tooltip: 'Đoạn sau',
                    color: settings.textColor,
                    onPressed: () {
                      if (tts.currentParagraphIndex <
                          tts.totalParagraphs - 1) {
                        tts.nextParagraph();
                      } else if (_hasNext) {
                        _goToChapter(_currentIndex + 1);
                      }
                    },
                  ),
                  // Time set hẹn giờ nghe/tắt
                  IconButton(
                    icon: Icon(
                      timerLeft > 0 || tts.stopAtEndOfChapter
                          ? Icons.alarm_on_rounded
                          : Icons.timer_outlined,
                    ),
                    tooltip: 'Hẹn giờ nghe / tắt',
                    color: timerLeft > 0 || tts.stopAtEndOfChapter
                        ? Colors.green
                        : settings.textColor,
                    onPressed: _showTtsTimerDialog,
                  ),
                  // Công cụ chỉnh tốc độ & độ cao
                  IconButton(
                    icon: const Icon(Icons.speed_rounded),
                    tooltip: 'Chỉnh tốc độ & độ cao',
                    color: settings.textColor,
                    onPressed: _showTtsSpeedPitchSheet,
                  ),
                  // Icon setting để hiện thanh setting
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: 'Cài đặt TTS chi tiết',
                    color: settings.textColor,
                    onPressed: () {
                      TtsControlSheet.show(
                        context,
                        textContent: _displayText.isNotEmpty
                            ? _displayText
                            : _content,
                        onNextChapter: _hasNext
                            ? () => _goToChapter(_currentIndex + 1)
                            : null,
                      );
                    },
                  ),
                  // Icon tắt để tắt TTS
                  IconButton(
                    icon: const Icon(Icons.power_settings_new_rounded),
                    tooltip: 'Tắt TTS',
                    color: Colors.red.shade400,
                    onPressed: () {
                      tts.stop();
                      setState(() => _isTtsMode = false);
                    },
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildChapterDrawer(
    BuildContext context,
    ReadingSettingsProvider settings,
  ) {
    final screenWidth = MediaQuery.of(context).size.width;
    final drawerWidth = screenWidth * 0.8;
    final chapters = widget.allChapters ?? [];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF161618) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    return SizedBox(
      width: drawerWidth,
      child: Drawer(
        backgroundColor: bgColor,
        elevation: 16,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(16)),
        ),
        child: SafeArea(
          child: StatefulBuilder(
            builder: (context, setDrawerState) {
              final query = _drawerSearchController.text.trim().toLowerCase();
              final filtered = query.isEmpty
                  ? chapters
                  : chapters
                      .where((c) => c.name.toLowerCase().contains(query))
                      .toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.format_list_bulleted_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Mục lục (${chapters.length} chương)',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: textColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.pop(context),
                          tooltip: 'Đóng',
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    child: TextField(
                      controller: _drawerSearchController,
                      style: TextStyle(fontSize: 13, color: textColor),
                      decoration: InputDecoration(
                        hintText: 'Tìm kiếm chương...',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _drawerSearchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () {
                                  setDrawerState(() {
                                    _drawerSearchController.clear();
                                  });
                                },
                              )
                            : null,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 10,
                        ),
                        filled: true,
                        fillColor: isDark
                            ? Colors.white.withAlpha(12)
                            : Colors.black.withAlpha(8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (_) => setDrawerState(() {}),
                    ),
                  ),
                  const Divider(height: 12),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text(
                              'Không tìm thấy chương',
                              style: TextStyle(
                                color: isDark ? Colors.white38 : Colors.black38,
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: _drawerScrollController,
                            itemCount: filtered.length,
                            itemBuilder: (context, idx) {
                              final ch = filtered[idx];
                              final origIdx = chapters.indexOf(ch);
                              final isCurrent = origIdx == _currentIndex;

                              return ListTile(
                                dense: true,
                                selected: isCurrent,
                                selectedTileColor: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withAlpha(25),
                                leading: isCurrent
                                    ? Icon(
                                        Icons.bookmark_rounded,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        size: 18,
                                      )
                                    : Text(
                                        '${origIdx + 1}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isDark
                                              ? Colors.white38
                                              : Colors.black38,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                title: Text(
                                  ch.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: isCurrent
                                        ? Theme.of(context).colorScheme.primary
                                        : textColor,
                                  ),
                                ),
                                onTap: () {
                                  Navigator.pop(context);
                                  _goToChapter(origIdx);
                                },
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _showTtsSpeedPitchSheet() {
    final tts = TtsService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF18181A) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return ListenableBuilder(
          listenable: tts,
          builder: (context, _) {
            final speedDisplay = (tts.speechRate * 200).round();
            final pitchDisplay = (tts.pitch * 100).round();

            return Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withAlpha(100),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Tốc độ & Độ cao giọng đọc',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Tốc độ đọc',
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '$speedDisplay',
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () {
                            final next =
                                (tts.speechRate - 0.05).clamp(0.25, 1.0);
                            tts.setSpeechRate(next);
                          },
                        ),
                        Expanded(
                          child: Slider(
                            value: tts.speechRate.clamp(0.25, 1.0),
                            min: 0.25,
                            max: 1.0,
                            divisions: 15,
                            onChanged: (v) => tts.setSpeechRate(v),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () {
                            final next =
                                (tts.speechRate + 0.05).clamp(0.25, 1.0);
                            tts.setSpeechRate(next);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Độ cao (Pitch)',
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '$pitchDisplay',
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () {
                            final next = (tts.pitch - 0.05).clamp(0.5, 1.5);
                            tts.setPitch(next);
                          },
                        ),
                        Expanded(
                          child: Slider(
                            value: tts.pitch.clamp(0.5, 1.5),
                            min: 0.5,
                            max: 1.5,
                            divisions: 20,
                            onChanged: (v) => tts.setPitch(v),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () {
                            final next = (tts.pitch + 0.05).clamp(0.5, 1.5);
                            tts.setPitch(next);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showTtsTimerDialog() {
    final tts = TtsService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF18181A) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return ListenableBuilder(
          listenable: tts,
          builder: (context, _) {
            final mins = tts.timerMinutesRemaining;
            final stopAtEnd = tts.stopAtEndOfChapter;

            return Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withAlpha(100),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Hẹn giờ dừng đọc TTS',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.timer_off_outlined),
                      title: const Text('Tắt hẹn giờ'),
                      trailing: (mins == 0 && !stopAtEnd)
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                      onTap: () {
                        tts.startSleepTimer(0);
                        Navigator.pop(ctx);
                      },
                    ),
                    for (final m in [15, 30, 45, 60])
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.timer_outlined),
                        title: Text('Hẹn giờ $m phút'),
                        trailing: (mins > 0 && (mins - m).abs() < 2)
                            ? const Icon(Icons.check, color: Colors.green)
                            : null,
                        onTap: () {
                          tts.startSleepTimer(m);
                          Navigator.pop(ctx);
                        },
                      ),
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.bookmark_outline),
                      title: const Text('Dừng khi hết chương hiện tại'),
                      trailing: stopAtEnd
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                      onTap: () {
                        tts.setStopAtEndOfChapter(true);
                        Navigator.pop(ctx);
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
