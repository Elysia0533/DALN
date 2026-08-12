import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../models/story.dart';
import '../models/reading_marker.dart';
import '../services/api_service.dart';
import '../theme/reading_settings_provider.dart';
import '../widgets/reader_selectable_text.dart';
import '../widgets/tts_control_sheet.dart';
import '../widgets/tts_player_container.dart';
import '../services/tts_service.dart';

class ReadingScreen extends StatefulWidget {
  final Story story;
  final double? initialScrollOffset;
  final int? initialParagraphIndex;

  const ReadingScreen({
    super.key,
    required this.story,
    this.initialScrollOffset,
    this.initialParagraphIndex,
  });

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
  bool _showEnglish = false;
  bool _showToolbar = false;
  bool _isBookmarked = false;

  final ScrollController _scrollController = ScrollController();
  double _scrollProgress = 0.0;
  Timer? _historySaveTimer;

  int _lastScrolledParagraphIndex = -1;

  @override
  void initState() {
    super.initState();
    _restoreScrollPosition();
    _loadBookmarkState();
    _scrollController.addListener(_onScroll);
    _setupTtsListener();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recordHistory();
      if (widget.initialScrollOffset != null || widget.initialParagraphIndex != null) {
        _scrollToBookmarkPosition(
          scrollOffset: widget.initialScrollOffset,
          paragraphIndex: widget.initialParagraphIndex,
        );
      }
    });
  }

  void _setupTtsListener() {
    TtsService.instance.addListener(_onTtsStateChange);
  }

  void _onTtsStateChange() {
    final tts = TtsService.instance;
    if (!mounted) return;

    if (tts.isPlaying &&
        tts.currentParagraphIndex != _lastScrolledParagraphIndex) {
      _lastScrolledParagraphIndex = tts.currentParagraphIndex;
      _scrollToParagraph(tts.currentParagraphIndex);
    }
  }

  void _scrollToParagraph(int index) {
    if (!_scrollController.hasClients) return;
    final paragraphs = TtsService.parseParagraphs(_currentContent);
    if (paragraphs.isEmpty) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return;

    final ratio = (index / (paragraphs.length)).clamp(0.0, 1.0);
    final targetOffset = (ratio * maxScroll).clamp(0.0, maxScroll);

    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }


  Future<void> _restoreScrollPosition() async {
    final offset = await ApiService.getScrollOffset(widget.story.id);
    if (!mounted) return;
    if (offset > 0 && _scrollController.hasClients) {
      _scrollController.jumpTo(offset);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final savedOffset = await ApiService.getScrollOffset(widget.story.id);
        if (!mounted) return;
        if (savedOffset > 0 && _scrollController.hasClients) {
          _scrollController.jumpTo(
            savedOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          );
        }
      });
    }
  }

  void _onScroll() {
    final max = _scrollController.position.maxScrollExtent;
    final current = _scrollController.offset;
    if (max > 0) {
      setState(() => _scrollProgress = current / max);
    }
    ApiService.saveScrollOffset(widget.story.id, current);
    _scheduleHistorySave(current);
  }

  String get _currentContent =>
      _showEnglish && widget.story.contentEng.isNotEmpty
      ? widget.story.contentEng
      : widget.story.content;



  (int, String) _getCurrentParagraphInfo() {
    final paragraphs = _currentContent
        .split(RegExp(r'\r?\n+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (paragraphs.isEmpty) return (0, '');
    final maxScroll = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    final currentScroll = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final ratio = (maxScroll > 0)
        ? (currentScroll / maxScroll).clamp(0.0, 1.0)
        : 0.0;
    final idx = (ratio * (paragraphs.length - 1)).round();
    return (idx, paragraphs[idx]);
  }

  (int, String) _getParagraphInfoForText(String selectedText) {
    final paragraphs = _currentContent
        .split(RegExp(r'\r?\n+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (paragraphs.isEmpty) return (0, selectedText);
    final idx = paragraphs.indexWhere(
      (p) => p.contains(selectedText) || selectedText.contains(p),
    );
    if (idx != -1) {
      return (idx, paragraphs[idx]);
    }
    return _getCurrentParagraphInfo();
  }

  Future<void> _loadBookmarkState() async {
    final (pIdx, _) = _getCurrentParagraphInfo();
    final bookmarked = await ApiService.isBookmarked(
      widget.story.id,
      paragraphIndex: pIdx,
    );
    if (!mounted) return;
    setState(() => _isBookmarked = bookmarked);
  }

  void _scheduleHistorySave(double offset) {
    _historySaveTimer?.cancel();
    _historySaveTimer = Timer(
      const Duration(milliseconds: 700),
      () => _recordHistory(offset: offset),
    );
  }

  Future<void> _recordHistory({double? offset}) {
    return ApiService.recordReadingHistory(
      widget.story,
      chapterTitle: 'Vị trí ${(_scrollProgress * 100).round()}%',
      scrollOffset:
          offset ??
          (_scrollController.hasClients ? _scrollController.offset : 0),
    );
  }

  Future<void> _toggleBookmark({int? targetParagraphIndex, String? targetSnippet}) async {
    final (pIdx, pSnippet) = targetParagraphIndex != null
        ? (targetParagraphIndex, targetSnippet ?? '')
        : _getCurrentParagraphInfo();
    final added = await ApiService.toggleBookmark(
      widget.story,
      paragraphIndex: pIdx,
      chapterTitle: 'Vị trí ${(_scrollProgress * 100).round()}%',
      snippet: pSnippet.isNotEmpty ? _shortQuote(pSnippet) : '',
      scrollOffset: _scrollController.hasClients ? _scrollController.offset : 0,
    );
    if (!mounted) return;
    setState(() => _isBookmarked = added);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added ? 'Đã thêm bookmark (Đoạn ${pIdx + 1})' : 'Đã bỏ bookmark'),
        duration: const Duration(milliseconds: 1100),
      ),
    );
  }

  Future<void> _saveSelectionNote(String selectedText) async {
    final (pIdx, _) = _getParagraphInfoForText(selectedText);
    final added = await ApiService.toggleBookmark(
      widget.story,
      paragraphIndex: pIdx,
      chapterTitle: 'Vị trí ${(_scrollProgress * 100).round()}%',
      snippet: selectedText,
      scrollOffset: _scrollController.hasClients ? _scrollController.offset : 0,
    );
    if (!mounted) return;
    setState(() => _isBookmarked = added);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added
              ? 'Đã đánh dấu đoạn ${pIdx + 1}: ${_shortQuote(selectedText)}'
              : 'Đã bỏ đánh dấu đoạn ${pIdx + 1}',
        ),
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  Future<void> _speakSelectionFromParagraph(
    String selectedText,
    int targetParagraphIndex, {
    int? start,
    int? end,
  }) async {
    await TtsService.instance.speakFromSelection(
      fullText: _currentContent,
      selectedText: selectedText,
      selectionStart: start,
      selectionEnd: end,
      targetParagraphIndex: targetParagraphIndex,
      storyId: widget.story.id,
    );
  }

  Future<void> _speakSelection(String selectedText) async {

    await TtsService.instance.speakFromSelection(
      fullText: _currentContent,
      selectedText: selectedText,
      storyId: widget.story.id,
    );
  }



  void _showSelectionSearch(String selectedText) {
    final query = selectedText.trim();
    if (query.isEmpty) return;
    final count = RegExp(
      RegExp.escape(query),
      caseSensitive: false,
    ).allMatches(_currentContent).length;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _SelectionSearchSheet(query: query, count: count),
    );
  }

  void _shareSelection(String selectedText) {
    Clipboard.setData(
      ClipboardData(text: '"$selectedText"\n\n- ${widget.story.title}'),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Đã sao chép đoạn chọn để chia sẻ'),
        duration: Duration(milliseconds: 1100),
      ),
    );
  }

  String _shortQuote(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 48) return compact;
    return '${compact.substring(0, 48)}...';
  }

  void _scrollToBookmarkPosition({double? scrollOffset, int? paragraphIndex}) {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    double targetOffset = 0.0;
    if (scrollOffset != null && scrollOffset > 0) {
      targetOffset = scrollOffset;
    } else if (paragraphIndex != null && paragraphIndex > 0) {
      final paragraphs = _currentContent
          .split(RegExp(r'\r?\n+'))
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();
      if (paragraphs.isNotEmpty) {
        final ratio = (paragraphIndex / (paragraphs.length - 1)).clamp(0.0, 1.0);
        targetOffset = ratio * maxScroll;
      }
    }
    _scrollController.jumpTo(targetOffset.clamp(0.0, maxScroll));
  }

  Future<void> _showBookmarks() async {
    final bookmarks = await ApiService.getReadingBookmarks(
      storyId: widget.story.id,
    );
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _TextBookmarksSheet(
        bookmarks: bookmarks,
        onSelect: (marker) {
          Navigator.pop(context);
          _scrollToBookmarkPosition(
            scrollOffset: marker.scrollOffset,
            paragraphIndex: marker.paragraphIndex,
          );
        },
        onRemove: (marker) async {
          await ApiService.removeBookmark(marker.id);
          await _loadBookmarkState();
          if (!mounted) return;
          Navigator.pop(context);
          _showBookmarks();
        },
      ),
    );
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _SettingsSheet(),
    );
  }

  void _handleReaderMenuAction(String action) {
    switch (action) {
      case 'language':
        setState(() => _showEnglish = !_showEnglish);
        break;
      case 'bookmarks':
        _showBookmarks();
        break;
      case 'settings':
        _showSettings();
        break;
      case 'audio':
        TtsControlSheet.show(context, textContent: _currentContent);
        break;
    }
  }

  @override
  void dispose() {
    _historySaveTimer?.cancel();
    if (_scrollController.hasClients) {
      _recordHistory(offset: _scrollController.offset);
    }
    TtsService.instance.removeListener(_onTtsStateChange);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ReadingSettingsProvider>();

    return Scaffold(
      backgroundColor: settings.bgColor,
      body: GestureDetector(
        onTap: () => setState(() => _showToolbar = !_showToolbar),
        child: Stack(
          children: [
            SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 56),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 50),
                      ReaderSelectableText(
                        widget.story.title,
                        style: settings.bodyTextStyle.copyWith(
                          fontSize: settings.fontSize + 4,
                          fontWeight: FontWeight.bold,
                        ),
                        onNote: _saveSelectionNote,
                        onSpeak: _speakSelection,
                        onSearch: _showSelectionSearch,
                        onSettings: (_) => _showSettings(),
                        onShare: _shareSelection,
                      ),
                      const SizedBox(height: 24),
                      Builder(
                        builder: (context) {
                          final parsedParagraphs = TtsService.parseParagraphs(_currentContent);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: List.generate(parsedParagraphs.length, (i) {
                              final p = parsedParagraphs[i];
                              return _ParagraphWidget(
                                key: ValueKey('rs_p_$i'),
                                paragraphIndex: i,
                                chapterIndex: 0,
                                text: p.text,
                                style: settings.bodyTextStyle,
                                onNote: _saveSelectionNote,
                                onSpeak: (selectedText) =>
                                    _speakSelectionFromParagraph(selectedText, i),
                                onSelectionSpeak: (selectedText, start, end) =>
                                    _speakSelectionFromParagraph(
                                  selectedText,
                                  i,
                                  start: start,
                                  end: end,
                                ),
                                onSearch: _showSelectionSearch,
                                onSettings: (_) => _showSettings(),
                                onShare: _shareSelection,
                              );
                            }),
                          );
                        },
                      ),

                      const SizedBox(height: 80),
                      _TextEndCard(
                        textColor: settings.textColor,
                        accentColor: Theme.of(context).primaryColor,
                        progress: _scrollProgress,
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),

            AnimatedSlide(
              duration: const Duration(milliseconds: 250),
              offset: _showToolbar ? Offset.zero : const Offset(0, -1),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 250),
                opacity: _showToolbar ? 1 : 0,
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
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
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
                                  widget.story.title,
                                  style: settings.bodyTextStyle.copyWith(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    height: 1.1,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _showEnglish ? 'Bản tiếng Anh' : 'Văn bản',
                                  style: TextStyle(
                                    color: settings.textColor.withValues(
                                      alpha: 0.58,
                                    ),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              _isBookmarked
                                  ? Icons.bookmark_rounded
                                  : Icons.bookmark_border_rounded,
                              color: _isBookmarked
                                  ? Theme.of(context).primaryColor
                                  : settings.textColor,
                            ),
                            tooltip: _isBookmarked
                                ? 'Bỏ bookmark'
                                : 'Thêm bookmark',
                            onPressed: _toggleBookmark,
                          ),
                          PopupMenuButton<String>(
                            tooltip: 'Tác vụ đọc',
                            icon: Icon(
                              Icons.more_vert_rounded,
                              color: settings.textColor,
                            ),
                            onSelected: _handleReaderMenuAction,
                            itemBuilder: (context) => [
                              if (widget.story.contentEng.isNotEmpty)
                                PopupMenuItem(
                                  value: 'language',
                                  child: _TextReaderMenuItem(
                                    icon: Icons.language,
                                    label: _showEnglish
                                        ? 'Xem tiếng Việt'
                                        : 'Xem tiếng Anh',
                                  ),
                                ),
                              const PopupMenuItem(
                                value: 'bookmarks',
                                child: _TextReaderMenuItem(
                                  icon: Icons.bookmarks_outlined,
                                  label: 'Danh sách bookmark',
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'settings',
                                child: _TextReaderMenuItem(
                                  icon: Icons.text_fields_rounded,
                                  label: 'Cài đặt chữ',
                                ),
                              ),
                              PopupMenuItem(
                                value: 'audio',
                                child: _TextReaderMenuItem(
                                  icon: TtsService.instance.isPlaying
                                      ? Icons.pause_circle_outline
                                      : Icons.play_circle_outline,
                                  label: TtsService.instance.isPlaying
                                      ? 'Tạm dừng audio'
                                      : 'Đọc bằng audio',
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

            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 250),
                offset: _showToolbar ? Offset.zero : const Offset(0, 1),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  opacity: _showToolbar ? 1 : 0,
                  child: Container(
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
                          LinearProgressIndicator(
                            value: _scrollProgress.clamp(0.0, 1.0),
                            minHeight: 2,
                            backgroundColor: settings.textColor.withValues(
                              alpha: 0.10,
                            ),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Theme.of(context).primaryColor,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _showEnglish
                                            ? 'Bản tiếng Anh'
                                            : 'Văn bản',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: settings.textColor.withValues(
                                            alpha: 0.68,
                                          ),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${(_scrollProgress * 100).round()}%',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context).primaryColor,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 6,
                                    ),
                                  ),
                                  child: Slider(
                                    value: _scrollProgress.clamp(0.0, 1.0),
                                    onChanged: (v) {
                                      final max = _scrollController
                                          .position
                                          .maxScrollExtent;
                                      _scrollController.jumpTo(v * max);
                                    },
                                    activeColor: Theme.of(context).primaryColor,
                                    inactiveColor: settings.textColor
                                        .withValues(alpha: 0.2),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TtsPlayerContainer(
                            textColor: settings.textColor,
                            onOpenSettings: () => TtsControlSheet.show(
                              context,
                              textContent: _currentContent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}



class _SelectionSearchSheet extends StatelessWidget {
  final String query;
  final int count;

  const _SelectionSearchSheet({required this.query, required this.count});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 18,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.search_rounded, color: colorScheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Tìm trong chương',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              query,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              count == 0
                  ? 'Không tìm thấy kết quả trùng khớp.'
                  : 'Tìm thấy $count kết quả trùng khớp.',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextReaderMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;

  const _TextReaderMenuItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
    );
  }
}

class _TextEndCard extends StatelessWidget {
  final Color textColor;
  final Color accentColor;
  final double progress;

  const _TextEndCard({
    required this.textColor,
    required this.accentColor,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: textColor.withValues(alpha: 0.10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            color: progress >= 0.98
                ? accentColor
                : textColor.withValues(alpha: 0.54),
            size: 28,
          ),
          const SizedBox(height: 8),
          Text(
            'Hết nội dung',
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tiến độ ${((progress.clamp(0.0, 1.0)) * 100).round()}%',
            style: TextStyle(
              color: textColor.withValues(alpha: 0.58),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TextBookmarksSheet extends StatelessWidget {
  final List<ReadingMarker> bookmarks;
  final ValueChanged<ReadingMarker> onSelect;
  final ValueChanged<ReadingMarker> onRemove;

  const _TextBookmarksSheet({
    required this.bookmarks,
    required this.onSelect,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final bg = isDark ? const Color(0xFF1C1C1E) : Colors.white;

    return Container(
      constraints: const BoxConstraints(maxHeight: 380),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 14),
              decoration: BoxDecoration(
                color: colorScheme.outline.withValues(alpha: 0.38),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Bookmark',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    '${bookmarks.length}',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            if (bookmarks.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
                child: Column(
                  children: [
                    Icon(
                      Icons.bookmark_border_rounded,
                      size: 44,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Chưa có bookmark cho truyện này',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: bookmarks.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    color: colorScheme.outline.withValues(alpha: 0.12),
                  ),
                  itemBuilder: (context, index) {
                    final marker = bookmarks[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: colorScheme.primary.withValues(
                          alpha: 0.12,
                        ),
                        child: Icon(
                          Icons.bookmark_rounded,
                          color: colorScheme.primary,
                        ),
                      ),
                      title: Text(
                        marker.snippet.isNotEmpty
                            ? '"${marker.snippet}"'
                            : (marker.chapterTitle.isNotEmpty
                                ? marker.chapterTitle
                                : 'Bookmark'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        'Đoạn ${marker.paragraphIndex + 1}${marker.chapterTitle.isNotEmpty ? ' • ${marker.chapterTitle}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => onSelect(marker),
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Xóa bookmark',
                        onPressed: () => onRemove(marker),
                      ),
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

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ReadingSettingsProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

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
            'Cỡ chữ',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
          Row(
            children: [
              IconButton(
                onPressed: () => settings.setFontSize(settings.fontSize - 1),
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Expanded(
                child: Slider(
                  value: settings.fontSize,
                  min: 12,
                  max: 28,
                  divisions: 16,
                  label: settings.fontSize.toInt().toString(),
                  onChanged: settings.setFontSize,
                ),
              ),
              IconButton(
                onPressed: () => settings.setFontSize(settings.fontSize + 1),
                icon: const Icon(Icons.add_circle_outline),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${settings.fontSize.toInt()}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Dãn dòng',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
          Row(
            children: [
              IconButton(
                onPressed: () =>
                    settings.setLineHeight(settings.lineHeight - 0.1),
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Expanded(
                child: Slider(
                  value: settings.lineHeight,
                  min: 1.2,
                  max: 2.2,
                  divisions: 10,
                  label: settings.lineHeight.toStringAsFixed(1),
                  onChanged: settings.setLineHeight,
                ),
              ),
              IconButton(
                onPressed: () =>
                    settings.setLineHeight(settings.lineHeight + 0.1),
                icon: const Icon(Icons.add_circle_outline),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  settings.lineHeight.toStringAsFixed(1),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Phông chữ',
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
            children: ReadingSettingsProvider.availableFonts.map((f) {
              final isSelected = settings.fontFamily == f['name'];
              return ChoiceChip(
                label: Text(f['label']!),
                selected: isSelected,
                onSelected: (_) => settings.setFontFamily(f['name']!),
                selectedColor: Theme.of(context).primaryColor,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : textColor,
                  fontSize: 13,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Text(
            'Màu nền',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
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
                          ? Theme.of(context).primaryColor
                          : Colors.grey.shade300,
                      width: isSelected ? 3 : 1,
                    ),
                  ),
                  child: isSelected
                      ? Icon(
                          Icons.check,
                          color: Color(c['textColor'] as int),
                          size: 20,
                        )
                      : null,
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _ParagraphWidget extends StatelessWidget {
  final int paragraphIndex;
  final int chapterIndex;
  final String text;
  final TextStyle style;
  final ReaderTextAction? onNote;
  final ReaderTextAction? onSpeak;
  final ReaderSelectionAction? onSelectionSpeak;
  final ReaderTextAction? onSearch;
  final ReaderTextAction? onSettings;
  final ReaderTextAction? onShare;

  const _ParagraphWidget({
    super.key,
    required this.paragraphIndex,
    required this.chapterIndex,
    required this.text,
    required this.style,
    this.onNote,
    this.onSpeak,
    this.onSelectionSpeak,
    this.onSearch,
    this.onSettings,
    this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TtsService.instance,
      builder: (context, _) {
        final tts = TtsService.instance;
        final isCurrent = (tts.isPlaying || tts.isPaused) &&
            tts.currentParagraphIndex == paragraphIndex;

        final colorScheme = Theme.of(context).colorScheme;
        final highlightColor = isCurrent
            ? colorScheme.primaryContainer.withValues(alpha: 0.35)
            : Colors.transparent;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: highlightColor,
            borderRadius: BorderRadius.circular(8),
            border: isCurrent
                ? Border.all(
                    color: colorScheme.primary.withValues(alpha: 0.4),
                    width: 1,
                  )
                : null,
          ),
          child: ReaderSelectableText(
            text,
            style: style,
            onNote: onNote,
            onSpeak: onSpeak,
            onSelectionSpeak: onSelectionSpeak,
            onSearch: onSearch,
            onSettings: onSettings,
            onShare: onShare,
          ),
        );
      },
    );
  }
}

