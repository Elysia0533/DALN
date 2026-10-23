import 'dart:io';
import 'package:flutter/material.dart';
import '../models/story.dart';
import '../services/api_service.dart';
import '../services/local_manga_parser.dart';

class _LocalChapter {
  final String title;
  final List<File> imageFiles;

  _LocalChapter({required this.title, required this.imageFiles});
}

class LocalComicReaderScreen extends StatefulWidget {
  final Story story;
  final int? initialChapterIndex;

  const LocalComicReaderScreen({
    super.key,
    required this.story,
    this.initialChapterIndex,
  });

  @override
  State<LocalComicReaderScreen> createState() => _LocalComicReaderScreenState();
}

class _LocalComicReaderScreenState extends State<LocalComicReaderScreen> {
  final ScrollController _scrollController = ScrollController();
  List<_LocalChapter> _chapters = [];
  int _currentChapterIndex = 0;
  bool _isLoading = true;
  String? _error;
  bool _showBars = true;

  @override
  void initState() {
    super.initState();
    _loadChapters();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadChapters() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final parsed = await LocalMangaParser.parse(directoryPath: widget.story.localPath);
      if (parsed == null || parsed.chapters.isEmpty) {
        throw Exception('Không tìm thấy tệp ảnh truyện tranh (.jpg, .png...) hoặc file chỉ mục chapter.json trong thư mục: ${widget.story.localPath}');
      }

      final chapters = parsed.chapters
          .map((c) => _LocalChapter(
                title: c.title,
                imageFiles: c.imageFiles,
              ))
          .toList();

      int targetIndex = widget.initialChapterIndex ?? widget.story.savedChapterIndex;
      if (targetIndex < 0 || targetIndex >= chapters.length) {
        targetIndex = 0;
      }

      if (mounted) {
        setState(() {
          _chapters = chapters;
          _currentChapterIndex = targetIndex;
          _isLoading = false;
        });
        _saveProgress();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  void _saveProgress() {
    if (_chapters.isEmpty) return;
    ApiService.saveChapterProgress(
      widget.story.id,
      _currentChapterIndex,
      totalChapters: _chapters.length,
    );
  }

  void _goToChapter(int index) {
    if (index < 0 || index >= _chapters.length) return;
    setState(() {
      _currentChapterIndex = index;
    });
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    _saveProgress();
  }

  void _showChapterListModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Danh sách chương',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${_chapters.length} chương',
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12),
              Expanded(
                child: ListView.builder(
                  itemCount: _chapters.length,
                  itemBuilder: (ctx, idx) {
                    final isCurrent = idx == _currentChapterIndex;
                    final ch = _chapters[idx];
                    return ListTile(
                      selected: isCurrent,
                      selectedTileColor: Colors.pinkAccent.withAlpha(30),
                      leading: Icon(
                        isCurrent ? Icons.play_arrow_rounded : Icons.menu_book_rounded,
                        color: isCurrent ? Colors.pinkAccent : Colors.white54,
                      ),
                      title: Text(
                        ch.title,
                        style: TextStyle(
                          color: isCurrent ? Colors.pinkAccent : Colors.white,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      trailing: Text(
                        '${ch.imageFiles.length} trang',
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _goToChapter(idx);
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
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.pinkAccent)),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
                const SizedBox(height: 16),
                Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _loadChapters,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Thử lại'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final currentChapter = _chapters[_currentChapterIndex];
    final images = currentChapter.imageFiles;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Khung đọc truyện tranh vuốt mượt mà
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => setState(() => _showBars = !_showBars),
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 3.5,
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: 60),
                itemCount: images.length + 1,
                itemBuilder: (context, idx) {
                  if (idx == images.length) {
                    // Nút chuyển chương ở cuối trang
                    return Container(
                      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_currentChapterIndex > 0)
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.white70),
                              onPressed: () => _goToChapter(_currentChapterIndex - 1),
                              icon: const Icon(Icons.chevron_left_rounded),
                              label: const Text('Chương trước'),
                            ),
                          const SizedBox(width: 16),
                          if (_currentChapterIndex < _chapters.length - 1)
                            FilledButton.icon(
                              style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
                              onPressed: () => _goToChapter(_currentChapterIndex + 1),
                              icon: const Icon(Icons.chevron_right_rounded),
                              label: const Text('Chương kế tiếp'),
                            ),
                        ],
                      ),
                    );
                  }

                  final file = images[idx];
                  return Image.file(
                    file,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Container(
                      height: 200,
                      color: Colors.grey.shade900,
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.broken_image_rounded, color: Colors.white38),
                            SizedBox(height: 8),
                            Text('Không thể hiển thị trang tranh này', style: TextStyle(color: Colors.white38, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Thanh Top Bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 200),
              offset: _showBars ? Offset.zero : const Offset(0, -1),
              child: Container(
                padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top, left: 8, right: 16, bottom: 8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.black87, Colors.transparent],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.story.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${currentChapter.title} • (${images.length} trang)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Thanh Bottom Bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 200),
              offset: _showBars ? Offset.zero : const Offset(0, 1),
              child: Container(
                padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 8, top: 8, left: 16, right: 16),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Colors.black87],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left_rounded, color: Colors.white, size: 28),
                      tooltip: 'Chương trước',
                      onPressed: _currentChapterIndex > 0 ? () => _goToChapter(_currentChapterIndex - 1) : null,
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: Colors.white),
                      icon: const Icon(Icons.format_list_bulleted_rounded, size: 20),
                      label: Text('${_currentChapterIndex + 1}/${_chapters.length}'),
                      onPressed: _showChapterListModal,
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 28),
                      tooltip: 'Chương sau',
                      onPressed: _currentChapterIndex < _chapters.length - 1
                          ? () => _goToChapter(_currentChapterIndex + 1)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
