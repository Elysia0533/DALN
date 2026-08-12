import 'package:flutter/material.dart';
import '../models/reading_progress.dart';
import '../models/story.dart';
import '../models/plugin_info.dart';
import '../services/bookmark_service.dart';
import '../services/api_service.dart';
import '../services/extension_service.dart';
import 'chapter_reader_screen.dart';
import 'reading_screen.dart';
import 'pdf_reader_screen.dart';
import 'online_chapter_reader_screen.dart';

class BookmarksScreen extends StatefulWidget {
  const BookmarksScreen({super.key});

  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends State<BookmarksScreen> {
  List<Bookmark> _bookmarks = [];
  bool _isLoading = true;
  List<Story> _localStories = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final legacyBookmarks = await BookmarkService.getAllBookmarks();
    final apiMarkers = await ApiService.getReadingBookmarks();
    final localStories = await ApiService.fetchPersonalStories();

    final convertedMarkers = apiMarkers.map((m) => Bookmark(
      id: m.id,
      storyId: m.storyId,
      storyTitle: m.storyTitle,
      chapterIndex: m.chapterIndex,
      paragraphIndex: m.paragraphIndex,
      chapterTitle: m.chapterTitle,
      selectedText: m.snippet,
      scrollOffset: m.scrollOffset,
      createdAt: m.createdAt,
    )).toList();

    final seenIds = <String>{};
    final combined = <Bookmark>[];
    for (final b in [...convertedMarkers, ...legacyBookmarks]) {
      final key = b.id.isNotEmpty ? b.id : '${b.storyId}_${b.chapterIndex}_${b.paragraphIndex}';
      if (seenIds.add(key)) {
        combined.add(b);
      }
    }
    combined.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (mounted) {
      setState(() {
        _bookmarks = combined;
        _localStories = localStories;
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteBookmark(Bookmark bookmark) async {
    await BookmarkService.removeBookmark(bookmark.storyId, bookmark.id);
    await ApiService.removeBookmark(bookmark.id);
    setState(() {
      _bookmarks.removeWhere((b) => b.id == bookmark.id);
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Đã xoá dấu trang')),
    );
  }

  Future<void> _openBookmark(Bookmark bookmark) async {
    try {
      final story = _localStories.firstWhere((s) => s.id == bookmark.storyId);
      if (story.pluginId.isNotEmpty && story.storyUrl.isNotEmpty) {
        final installed = await ExtensionService.getInstalledPlugins();
        final plugin = installed.firstWhere(
          (p) => p.id == story.pluginId,
          orElse: () => PluginInfo(
            id: story.pluginId,
            name: story.pluginId,
            version: 1,
            author: 'vBook',
            description: '',
            iconUrl: '',
            downloadUrl: '',
            locale: 'vi',
            source: '',
            type: story.fileType == 'comic' ? 'comic' : 'novel',
          ),
        );
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => OnlineChapterReaderScreen(
              plugin: plugin,
              chapterUrl: story.storyUrl,
              chapterTitle: bookmark.chapterTitle.isNotEmpty ? bookmark.chapterTitle : 'Chương ${bookmark.chapterIndex + 1}',
              storyTitle: story.title,
              currentIndex: bookmark.chapterIndex,
            ),
          ),
        );
        return;
      }

      if (story.fileType == 'pdf') {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PdfReaderScreen(story: story),
          ),
        );
      } else if (story.fileType == 'txt') {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ReadingScreen(
              story: story,
              initialScrollOffset: bookmark.scrollOffset,
              initialParagraphIndex: bookmark.paragraphIndex,
            ),
          ),
        );
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChapterReaderScreen(
              story: story,
              initialChapterIndex: bookmark.chapterIndex,
              initialScrollOffset: bookmark.scrollOffset,
              initialParagraphIndex: bookmark.paragraphIndex,
            ),
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không tìm thấy truyện trong thiết bị. Vui lòng tải lại truyện.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dấu trang của tôi'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _bookmarks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bookmark_outline, size: 64, color: isDark ? Colors.grey.shade600 : Colors.grey.shade400),
                      const SizedBox(height: 16),
                      Text('Bạn chưa có dấu trang nào', style: TextStyle(color: isDark ? Colors.grey.shade400 : Colors.grey.shade600)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _bookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = _bookmarks[index];
                    final chapterText = bookmark.chapterTitle.isNotEmpty
                        ? bookmark.chapterTitle
                        : 'Chương ${bookmark.chapterIndex + 1}';
                    return ListTile(
                      leading: Icon(Icons.bookmark, color: Color(bookmark.colorValue)),
                      title: Text(bookmark.storyTitle.isNotEmpty ? bookmark.storyTitle : 'Truyện không tên'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('$chapterText • Đoạn ${bookmark.paragraphIndex + 1}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          if (bookmark.selectedText.isNotEmpty)
                            Text('"${bookmark.selectedText}"', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontStyle: FontStyle.italic)),
                        ],
                      ),
                      isThreeLine: bookmark.selectedText.isNotEmpty,
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteBookmark(bookmark),
                      ),
                      onTap: () => _openBookmark(bookmark),
                    );
                  },
                ),
    );
  }
}
