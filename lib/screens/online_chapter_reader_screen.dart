import 'package:flutter/material.dart' hide Page;
import 'package:provider/provider.dart';
import '../models/online_chapter_content.dart';
import '../widgets/chapter_image.dart';
import '../models/plugin_info.dart';
import '../services/plugin/vbook_engine_channel.dart';
import '../services/plugin/plugin_loader.dart';
import '../theme/reading_settings_provider.dart';
import '../widgets/reader_selectable_text.dart';
import '../widgets/tts_control_sheet.dart';
import '../widgets/tts_player_container.dart';
import '../services/tts_service.dart';
import '../services/offline_download_service.dart';
import '../services/han_viet_translator_service.dart';
import 'web_browser_screen.dart';

class OnlineChapterReaderScreen extends StatefulWidget {
  final PluginInfo plugin;
  final String chapterUrl;
  final String chapterTitle;
  final String storyTitle;
  final String? storyUrl;
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

class _OnlineChapterReaderScreenState extends State<OnlineChapterReaderScreen> {
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

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _bottomBarKey = GlobalKey();
  double _bottomBarHeight = 180;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.chapterUrl;
    _currentTitle = widget.chapterTitle;
    _currentIndex = widget.currentIndex;
    _loadContent();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
    _loadContent();
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
    if (block.isImage) return ChapterImage(block: block, referer: _currentUrl);
    final offset = _displayOffsets[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ReaderSelectableText(
        _displayBlocks[index],
        style: settings.bodyTextStyle,
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

    return Scaffold(
      backgroundColor: settings.bgColor,
      body: GestureDetector(
        onTap: () => setState(() => _showToolbars = !_showToolbars),
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
                  ? InteractiveViewer(
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
                    )
                  : SingleChildScrollView(
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        20,
                        72,
                        20,
                        _bottomBarHeight + 24,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 780),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 16),
                              Text(
                                _currentTitle,
                                style: settings.bodyTextStyle.copyWith(
                                  fontSize: settings.fontSize + 6,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 20),
                              for (var i = 0; i < _blocks.length; i++)
                                _buildBlock(i, settings),
                              const SizedBox(height: 60),
                              // End of Chapter indicator
                              Center(
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
                              const SizedBox(height: 40),
                            ],
                          ),
                        ),
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
                          ],
                        ),
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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.allChapters != null &&
                              widget.allChapters!.isNotEmpty) ...[
                            // Chapter Scrubbing Slider
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
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
                                        (widget.allChapters!.length - 1)
                                            .toDouble(),
                                      ),
                                      min: 0.0,
                                      max: (widget.allChapters!.length - 1)
                                          .toDouble(),
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

                            // Prev Chapter / Chapter Counter / Next Chapter Row
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  IconButton(
                                    onPressed: _hasPrevious
                                        ? () => _goToChapter(_currentIndex - 1)
                                        : null,
                                    icon: const Icon(
                                      Icons.chevron_left_rounded,
                                    ),
                                    tooltip: 'Chương trước',
                                  ),
                                  GestureDetector(
                                    onTap: _showChapterListModal,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: settings.textColor.withAlpha(15),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.menu_book_rounded,
                                            size: 14,
                                            color: settings.textColor.withAlpha(
                                              180,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '${_currentIndex + 1} / ${widget.allChapters!.length}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: settings.textColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: _hasNext
                                        ? () => _goToChapter(_currentIndex + 1)
                                        : null,
                                    tooltip: 'Chương sau',
                                    icon: const Icon(
                                      Icons.chevron_right_rounded,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          // Secondary Function Strip (Translate Hán-Việt, Download Offline, Export EPUB)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 4,
                              horizontal: 16,
                            ),
                            color: settings.textColor.withAlpha(10),
                            child: Wrap(
                              alignment: WrapAlignment.spaceEvenly,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                TextButton.icon(
                                  onPressed: () {
                                    setState(() {
                                      HanVietTranslatorService.instance
                                          .toggleTranslator();
                                    });
                                  },
                                  icon: Icon(
                                    Icons.g_translate_rounded,
                                    size: 16,
                                    color:
                                        HanVietTranslatorService
                                            .instance
                                            .enabled
                                        ? colorScheme.primary
                                        : settings.textColor.withAlpha(150),
                                  ),
                                  label: Text(
                                    HanVietTranslatorService.instance.enabled
                                        ? 'Hán-Việt (BẬT)'
                                        : 'Hán-Việt (TẮT)',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color:
                                          HanVietTranslatorService
                                              .instance
                                              .enabled
                                          ? colorScheme.primary
                                          : settings.textColor.withAlpha(150),
                                    ),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: _startDownload,
                                  icon: Icon(
                                    Icons.download_rounded,
                                    size: 16,
                                    color: settings.textColor.withAlpha(150),
                                  ),
                                  label: Text(
                                    'Tải Offline',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: settings.textColor.withAlpha(150),
                                    ),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: _exportEpub,
                                  icon: Icon(
                                    Icons.menu_book_outlined,
                                    size: 16,
                                    color: settings.textColor.withAlpha(150),
                                  ),
                                  label: Text(
                                    'Xuất EPUB',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: settings.textColor.withAlpha(150),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: _showToolbars ? _bottomBarHeight : 10,
              child: TtsPlayerContainer(
                textColor: settings.textColor,
                onPreviousChapter: _hasPrevious
                    ? () => _goToChapter(_currentIndex - 1)
                    : null,
                onNextChapter: _hasNext
                    ? () => _goToChapter(_currentIndex + 1)
                    : null,
                onOpenSettings: () {
                  TtsControlSheet.show(
                    context,
                    textContent: _content,
                    onNextChapter: _hasNext
                        ? () => _goToChapter(_currentIndex + 1)
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
