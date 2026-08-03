import 'dart:convert';
import 'package:flutter/material.dart' hide Page;
import 'package:cached_network_image/cached_network_image.dart';
import '../models/plugin_info.dart';
import '../models/source_models.dart';
import '../services/plugin/vbook_engine_channel.dart';
import '../services/plugin/plugin_loader.dart';
import '../widgets/reader_selectable_text.dart';
import '../widgets/tts_control_sheet.dart';
import '../services/offline_download_service.dart';
import '../services/han_viet_translator_service.dart';
import 'web_browser_screen.dart';

class OnlineChapterReaderScreen extends StatefulWidget {
  final PluginInfo plugin;
  final String chapterUrl;
  final String chapterTitle;
  final List<ChapterNav>? allChapters;
  final int currentIndex;

  const OnlineChapterReaderScreen({
    super.key,
    required this.plugin,
    required this.chapterUrl,
    required this.chapterTitle,
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
  bool _isLoading = true;
  String? _error;
  String _content = '';
  List<Page> _pages = [];
  bool _isComic = false;
  double _fontSize = 18.0;
  late int _currentIndex;
  late String _currentUrl;
  late String _currentTitle;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.currentIndex;
    _currentUrl = widget.chapterUrl;
    _currentTitle = widget.chapterTitle;
    _loadContent();
  }

  bool get _hasPrevious =>
      widget.allChapters != null && _currentIndex > 0;

  bool get _hasNext =>
      widget.allChapters != null &&
      _currentIndex < (widget.allChapters!.length - 1);

  String _cleanTextContent(String text) {
    if (text.isEmpty) return '';
    return text
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
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

    try {
      final dirPath = await PluginLoader.getPluginDir(widget.plugin.id);
      await VBookEngineChannel.loadSource(widget.plugin.id.hashCode, dirPath);

      final pagesList = await VBookEngineChannel.getPageList(widget.plugin.id.hashCode, _currentUrl);
      if (mounted) {
        setState(() {
          _pages = pagesList ?? [];
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

  Widget _buildComicPageImage(String rawUrl, ColorScheme colorScheme) {
    if (rawUrl.isEmpty) return const SizedBox.shrink();

    String imgUrl = rawUrl.trim();

    // Base64 decoding support (data:image/... or vbook-base64://...)
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

    // Pass custom Referer & User-Agent HTTP headers to bypass anti-hotlinking on comic CDNs
    final Map<String, String> headers = {
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Referer': widget.plugin.source.isNotEmpty && widget.plugin.source.startsWith('http')
          ? widget.plugin.source
          : imgUrl,
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
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentTitle, style: const TextStyle(fontSize: 14)),
        actions: [
          if (!_isComic) ...[
            IconButton(
              icon: const Icon(Icons.volume_up_rounded),
              tooltip: 'Đọc tự động (TTS & Nhạc nền)',
              onPressed: () {
                TtsControlSheet.show(
                  context,
                  textContent: _content,
                  onNextChapter: _hasNext ? () => _goToChapter(_currentIndex + 1) : null,
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.download_for_offline_rounded),
              tooltip: 'Tải offline & Xuất file',
              onPressed: () async {
                final chaptersMap = widget.allChapters?.map((c) => {'url': c.url, 'name': c.name}).toList() ?? [
                  {'url': _currentUrl, 'name': _currentTitle}
                ];
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Bắt đầu tải ${chaptersMap.length} chương xuống máy...'),
                    duration: const Duration(seconds: 3),
                  ),
                );

                await OfflineDownloadService.instance.startBatchDownload(
                  plugin: widget.plugin,
                  storyTitle: _currentTitle,
                  chapters: chaptersMap,
                  startFrom: _currentIndex,
                );
              },
            ),
            IconButton(
              icon: Icon(
                Icons.translate_rounded,
                color: HanVietTranslatorService.instance.enabled ? colorScheme.primary : null,
              ),
              tooltip: 'Dịch Hán-Việt / VietPhrase tự động',
              onPressed: () {
                setState(() {
                  HanVietTranslatorService.instance.toggleTranslator();
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      HanVietTranslatorService.instance.enabled
                          ? 'Đã BẬT dịch Hán-Việt tự động'
                          : 'Đã TẮT dịch Hán-Việt',
                    ),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: 'Xuất sách điện tử (.epub / .txt)',
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
                            ? 'Đã xuất file EPUB thành công: ${file.path}'
                            : 'Cần tải offline chương trước khi xuất EPUB!',
                      ),
                      duration: const Duration(seconds: 4),
                    ),
                  );
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.text_decrease),
              onPressed: () => setState(() => _fontSize = (_fontSize - 2).clamp(12.0, 40.0)),
            ),
            IconButton(
              icon: const Icon(Icons.text_increase),
              onPressed: () => setState(() => _fontSize = (_fontSize + 2).clamp(12.0, 40.0)),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.open_in_browser_outlined),
            tooltip: 'Mở trình duyệt / Đăng nhập',
            onPressed: _openBrowser,
          ),
        ],
      ),
      body: _isLoading
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
                        const Text(
                          'Không tải được nội dung chương',
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
                        const Text(
                          'Nguồn truyện có thể bị chặn địa lý (cần bật VPN), yêu cầu Cloudflare hoặc đăng nhập web.',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
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
                          onPressed: _loadContent,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Thử lại'),
                        ),
                      ],
                    ),
                  ),
                )
              : _isComic
                  ? ListView.builder(
                      padding: const EdgeInsets.only(bottom: 80),
                      itemCount: _pages.length,
                      itemBuilder: (context, index) {
                        final page = _pages[index];
                        final imgUrl = page.imageUrl.isNotEmpty ? page.imageUrl : page.url;
                        return _buildComicPageImage(imgUrl, colorScheme);
                      },
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                      child: ReaderSelectableText(
                        _content.isEmpty
                            ? 'Chương này chưa có nội dung.'
                            : HanVietTranslatorService.instance.translate(_content),
                        style: TextStyle(
                          fontSize: _fontSize,
                          height: 1.6,
                        ),
                      ),
                    ),
      // Thanh điều hướng chương ở dưới cùng
      bottomNavigationBar: widget.allChapters != null
          ? Container(
              decoration: BoxDecoration(
                color: colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
              ),
              padding: EdgeInsets.only(
                left: 8,
                right: 8,
                top: 4,
                bottom: MediaQuery.of(context).padding.bottom + 4,
              ),
              child: Row(
                children: [
                  // Nút chương trước
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _hasPrevious
                          ? () => _goToChapter(_currentIndex - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left, size: 20),
                      label: const Text('Chương trước'),
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerLeft,
                      ),
                    ),
                  ),
                  // Chỉ số chương
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '${_currentIndex + 1}/${widget.allChapters!.length}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  // Nút chương sau
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _hasNext
                          ? () => _goToChapter(_currentIndex + 1)
                          : null,
                      icon: const Text('Chương sau'),
                      label: const Icon(Icons.chevron_right, size: 20),
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerRight,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}
