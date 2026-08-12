import 'dart:convert';
import 'package:flutter/material.dart' hide Page;
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/plugin_info.dart';
import '../models/source_models.dart';
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
  final List<ChapterNav>? allChapters;
  final int currentIndex;

  const OnlineChapterReaderScreen({
    super.key,
    required this.plugin,
    required this.chapterUrl,
    required this.chapterTitle,
    this.storyTitle = '',
    this.allChapters,
    this.currentIndex = 0,
  });

  @override
  State<OnlineChapterReaderScreen> createState() => _OnlineChapterReaderScreenState();
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
  List<Page> _pages = [];
  String _content = '';
  bool _isComic = false;
  bool _showToolbars = true;

  bool get _hasPrevious => widget.allChapters != null && _currentIndex > 0;
  bool get _hasNext =>
      widget.allChapters != null &&
      _currentIndex < (widget.allChapters!.length - 1);

  final ScrollController _scrollController = ScrollController();

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

  String _cleanTextContent(String text) {
    return text
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'&nbsp;', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'&lt;', caseSensitive: false), '<')
        .replaceAll(RegExp(r'&gt;', caseSensitive: false), '>')
        .replaceAll(RegExp(r'&amp;', caseSensitive: false), '&')
        .replaceAll(RegExp(r'&quot;', caseSensitive: false), '"')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  Future<void> _loadContent() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _pages = [];
      _content = '';
    });

    final downloadedContent = await OfflineDownloadService.instance.getDownloadedChapterContent(
      widget.plugin.id,
      widget.storyTitle,
      _currentIndex,
    );

    if (downloadedContent != null && downloadedContent.trim().isNotEmpty) {
      if (mounted) {
        setState(() {
          final trimmed = downloadedContent.trim();
          if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
            try {
              final List<dynamic> list = jsonDecode(trimmed);
              _pages = list.asMap().entries.map((e) => Page(e.key, '', e.value.toString())).toList();
              _isComic = true;
            } catch (_) {
              _content = _cleanTextContent(trimmed);
              _isComic = false;
            }
          } else {
            _content = _cleanTextContent(trimmed);
            _isComic = false;
          }
          _isLoading = false;
        });

        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      }
      return;
    }

    try {
      final dirPath = await PluginLoader.getPluginDir(widget.plugin.id);
      await VBookEngineChannel.loadSource(widget.plugin.id, dirPath);

      final pagesList = await VBookEngineChannel.getPageList(widget.plugin.id, _currentUrl);
      if (mounted) {
        setState(() {
          _pages = pagesList;
          final firstUrl = _pages.isNotEmpty ? _pages.first.imageUrl : '';
          final isImageUrl = firstUrl.startsWith('http://') ||
              firstUrl.startsWith('https://') ||
              RegExp(r'\.(jpg|jpeg|png|webp|gif)', caseSensitive: false).hasMatch(firstUrl);

          _isComic = widget.plugin.type == 'comic' || (_pages.length > 1 && isImageUrl);

          if (!_isComic && _pages.isNotEmpty) {
            String rawContent = _pages.first.imageUrl;
            if (rawContent.startsWith('vbook-text://')) {
              rawContent = rawContent.substring(13);
            }
            _content = _cleanTextContent(rawContent);
          }
          _isLoading = false;
        });

        // Reset scroll position to top when chapter changes
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
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
        index >= widget.allChapters!.length) return;

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
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
                        fillColor: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (val) {
                        setModalState(() {
                          filteredChapters = widget.allChapters!
                              .where((c) => c.name.toLowerCase().contains(val.toLowerCase()))
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
                          selectedTileColor: theme.colorScheme.primaryContainer.withAlpha(80),
                          dense: true,
                          title: Text(
                            ch.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              color: isCurrent ? theme.colorScheme.primary : null,
                            ),
                          ),
                          trailing: isCurrent ? Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 18) : null,
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
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),

              // Font Size Slider
              Row(
                children: [
                  const Text('A-', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
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
                  const Text('A+', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 12),

              // Theme Selector
              Text('Màu nền giao diện:', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: ReadingSettingsProvider.bgColors.map((c) {
                  final colorVal = c['value'] as int;
                  final isSelected = settings.bgColor.value == colorVal;
                  return GestureDetector(
                    onTap: () => settings.setBgColor(colorVal),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Color(colorVal),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? theme.colorScheme.primary : Colors.grey.shade400,
                          width: isSelected ? 3 : 1,
                        ),
                        boxShadow: [
                          if (isSelected)
                            BoxShadow(color: theme.colorScheme.primary.withAlpha(100), blurRadius: 8),
                        ],
                      ),
                      child: isSelected
                          ? Icon(Icons.check, size: 20, color: Color(c['textColor'] as int))
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // Font Family Selector
              Text('Phông chữ:', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
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
                  Text('Khoảng cách dòng: ${settings.lineHeight.toStringAsFixed(1)}', style: theme.textTheme.bodySmall),
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

  Widget _buildComicPageImage(String rawUrl, ColorScheme colorScheme) {
    if (rawUrl.isEmpty) return const SizedBox.shrink();

    String imgUrl = rawUrl.trim();

    if (imgUrl.startsWith('vbook-base64://')) {
      final b64Str = imgUrl.substring(15);
      try {
        final bytes = base64Decode(b64Str);
        return Image.memory(bytes, fit: BoxFit.contain);
      } catch (_) {}
    }

    if (imgUrl.startsWith('data:image/')) {
      try {
        final commaIndex = imgUrl.indexOf(',');
        if (commaIndex != -1) {
          final b64Str = imgUrl.substring(commaIndex + 1);
          final bytes = base64Decode(b64Str);
          return Image.memory(bytes, fit: BoxFit.contain);
        }
      } catch (_) {}
    }

    final uri = Uri.tryParse(imgUrl);
    final imgHost = (uri != null && uri.host.isNotEmpty) ? '${uri.scheme}://${uri.host}/' : '';
    final referer = _currentUrl.startsWith('http')
        ? _currentUrl
        : (widget.plugin.source.startsWith('http') ? widget.plugin.source : imgHost);

    final Map<String, String> headers = {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Referer': referer,
    };

    return CachedNetworkImage(
      imageUrl: imgUrl,
      httpHeaders: headers,
      fit: BoxFit.contain,
      placeholder: (ctx, url) => Container(
        height: 350,
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        child: const Center(child: CircularProgressIndicator()),
      ),
      errorWidget: (ctx, url, err) {
        return Image.network(
          imgUrl,
          headers: headers,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              height: 250,
              color: colorScheme.errorContainer.withValues(alpha: 0.2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.broken_image_rounded, size: 48, color: Colors.red),
                  const SizedBox(height: 8),
                  Text(
                    'Không tải được ảnh (${err.toString().split("\n").first})',
                    style: const TextStyle(fontSize: 12, color: Colors.red),
                    textAlign: TextAlign.center,
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
    final settings = context.watch<ReadingSettingsProvider>();
    final colorScheme = Theme.of(context).colorScheme;

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
                                const Icon(Icons.cloud_off_rounded, size: 64, color: Colors.grey),
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
                                  style: TextStyle(fontSize: 12, color: settings.textColor.withAlpha(150)),
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
                                padding: const EdgeInsets.only(bottom: 80),
                                itemCount: _pages.length,
                                itemBuilder: (context, index) {
                                  final page = _pages[index];
                                  final imgUrl = page.imageUrl.isNotEmpty ? page.imageUrl : page.url;
                                  return _buildComicPageImage(imgUrl, colorScheme);
                                },
                              ),
                            )
                          : SingleChildScrollView(
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(20, 56, 20, 100),
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
                                      ReaderSelectableText(
                                        _content.isEmpty
                                            ? 'Chương này chưa có nội dung.'
                                            : HanVietTranslatorService.instance.translate(_content),
                                        style: settings.bodyTextStyle,
                                        onSelectionSpeak: (selectedText, start, end) {
                                          if (_content.isNotEmpty) {
                                            final translated = HanVietTranslatorService.instance.translate(_content);
                                            TtsService.instance.speakFromSelection(
                                              fullText: translated,
                                              selectedText: selectedText,
                                              selectionStart: start,
                                              selectionEnd: end,
                                              onChapterComplete: _hasNext ? () => _goToChapter(_currentIndex + 1) : null,
                                            );
                                          }
                                        },
                                      ),
                                      const SizedBox(height: 60),
                                      // End of Chapter indicator
                                      Center(
                                        child: Column(
                                          children: [
                                            Icon(Icons.check_circle_outline_rounded, color: settings.textColor.withAlpha(120), size: 36),
                                            const SizedBox(height: 8),
                                            Text(
                                              'Hết ${_currentTitle}',
                                              style: TextStyle(
                                                color: settings.textColor.withAlpha(150),
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            if (_hasNext)
                                              ElevatedButton.icon(
                                                onPressed: () => _goToChapter(_currentIndex + 1),
                                                icon: const Icon(Icons.arrow_forward),
                                                label: const Text('Đọc chương tiếp theo'),
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
            AnimatedSlide(
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
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(Icons.arrow_back_ios_new, color: settings.textColor, size: 20),
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
                              icon: Icon(Icons.volume_up_rounded, color: settings.textColor),
                              tooltip: 'Đọc tự động (TTS)',
                              onPressed: () {
                                TtsControlSheet.show(
                                  context,
                                  textContent: _content,
                                  onNextChapter: _hasNext ? () => _goToChapter(_currentIndex + 1) : null,
                                );
                              },
                            ),
                            IconButton(
                              icon: Icon(Icons.format_list_bulleted_rounded, color: settings.textColor),
                              tooltip: 'Mục lục chương',
                              onPressed: _showChapterListModal,
                            ),
                            IconButton(
                              icon: Icon(Icons.tune_rounded, color: settings.textColor),
                              tooltip: 'Tùy chỉnh giao diện',
                              onPressed: _showSettingsModal,
                            ),
                          ],
                          IconButton(
                            icon: Icon(Icons.open_in_browser_outlined, color: settings.textColor),
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
                          if (widget.allChapters != null && widget.allChapters!.isNotEmpty) ...[
                            // Chapter Scrubbing Slider
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                              child: Row(
                                children: [
                                  Text(
                                    '1',
                                    style: TextStyle(fontSize: 11, color: settings.textColor.withAlpha(150)),
                                  ),
                                  Expanded(
                                    child: Slider(
                                      value: _currentIndex.toDouble().clamp(0.0, (widget.allChapters!.length - 1).toDouble()),
                                      min: 0.0,
                                      max: (widget.allChapters!.length - 1).toDouble(),
                                      divisions: widget.allChapters!.length > 1 ? widget.allChapters!.length - 1 : 1,
                                      onChanged: (val) {
                                        _goToChapter(val.round());
                                      },
                                    ),
                                  ),
                                  Text(
                                    '${widget.allChapters!.length}',
                                    style: TextStyle(fontSize: 11, color: settings.textColor.withAlpha(150)),
                                  ),
                                ],
                              ),
                            ),

                            // Prev Chapter / Chapter Counter / Next Chapter Row
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  TextButton.icon(
                                    onPressed: _hasPrevious ? () => _goToChapter(_currentIndex - 1) : null,
                                    icon: const Icon(Icons.chevron_left_rounded),
                                    label: const Text('Trước'),
                                  ),
                                  GestureDetector(
                                    onTap: _showChapterListModal,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: settings.textColor.withAlpha(15),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.menu_book_rounded, size: 14, color: settings.textColor.withAlpha(180)),
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
                                  TextButton.icon(
                                    onPressed: _hasNext ? () => _goToChapter(_currentIndex + 1) : null,
                                    icon: const Text('Sau'),
                                    label: const Icon(Icons.chevron_right_rounded),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          // Secondary Function Strip (Translate Hán-Việt, Download Offline, Export EPUB)
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
                            color: settings.textColor.withAlpha(10),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                TextButton.icon(
                                  onPressed: () {
                                    setState(() {
                                      HanVietTranslatorService.instance.toggleTranslator();
                                    });
                                  },
                                  icon: Icon(
                                    Icons.g_translate_rounded,
                                    size: 16,
                                    color: HanVietTranslatorService.instance.enabled ? colorScheme.primary : settings.textColor.withAlpha(150),
                                  ),
                                  label: Text(
                                    HanVietTranslatorService.instance.enabled ? 'Hán-Việt (BẬT)' : 'Hán-Việt (TẮT)',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: HanVietTranslatorService.instance.enabled ? colorScheme.primary : settings.textColor.withAlpha(150),
                                    ),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () async {
                                    final chaptersMap = widget.allChapters?.map((c) => {'url': c.url, 'name': c.name}).toList() ?? [
                                      {'url': _currentUrl, 'name': _currentTitle}
                                    ];
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Bắt đầu tải ${chaptersMap.length} chương offline...'),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                    await OfflineDownloadService.instance.startBatchDownload(
                                      plugin: widget.plugin,
                                      storyTitle: _currentTitle,
                                      chapters: chaptersMap,
                                      startFrom: _currentIndex,
                                    );
                                  },
                                  icon: Icon(Icons.download_rounded, size: 16, color: settings.textColor.withAlpha(150)),
                                  label: Text(
                                    'Tải Offline',
                                    style: TextStyle(fontSize: 11, color: settings.textColor.withAlpha(150)),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () async {
                                    final file = await OfflineDownloadService.instance.exportToEpub(
                                      widget.plugin.id,
                                      _currentTitle,
                                      widget.allChapters?.length ?? 1,
                                    );
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            file != null
                                                ? 'Đã xuất file EPUB thành công!'
                                                : 'Hãy tải offline truyện trước khi xuất EPUB!',
                                          ),
                                        ),
                                      );
                                    }
                                  },
                                  icon: Icon(Icons.menu_book_outlined, size: 16, color: settings.textColor.withAlpha(150)),
                                  label: Text(
                                    'Xuất EPUB',
                                    style: TextStyle(fontSize: 11, color: settings.textColor.withAlpha(150)),
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
              bottom: _showToolbars ? 110 : 10,
              child: TtsPlayerContainer(
                textColor: settings.textColor,
                onPreviousChapter: _hasPrevious ? () => _goToChapter(_currentIndex - 1) : null,
                onNextChapter: _hasNext ? () => _goToChapter(_currentIndex + 1) : null,
                onOpenSettings: () {
                  TtsControlSheet.show(
                    context,
                    textContent: _content,
                    onNextChapter: _hasNext ? () => _goToChapter(_currentIndex + 1) : null,
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
