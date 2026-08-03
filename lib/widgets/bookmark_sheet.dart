import 'package:flutter/material.dart';
import '../models/reading_progress.dart';
import '../services/bookmark_service.dart';

class BookmarkSheet extends StatefulWidget {
  final String storyId;
  final void Function(Bookmark) onBookmarkSelected;

  const BookmarkSheet({
    super.key,
    required this.storyId,
    required this.onBookmarkSelected,
  });

  @override
  State<BookmarkSheet> createState() => _BookmarkSheetState();
}

class _BookmarkSheetState extends State<BookmarkSheet> {
  List<Bookmark> _bookmarks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
  }

  Future<void> _loadBookmarks() async {
    final bms = await BookmarkService.getBookmarks(widget.storyId);
    setState(() {
      _bookmarks = bms;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: Column(
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
            'Bookmarks (${_bookmarks.length})',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _bookmarks.isEmpty
                    ? Center(
                        child: Text(
                          'Chưa có bookmark nào.',
                          style: TextStyle(color: textColor.withValues(alpha: 0.6)),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _bookmarks.length,
                        itemBuilder: (context, index) {
                          final bm = _bookmarks[index];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              bm.selectedText.isNotEmpty
                                  ? '"${bm.selectedText}"'
                                  : bm.chapterTitle.isNotEmpty
                                      ? bm.chapterTitle
                                      : 'Bookmark ${index + 1}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: textColor),
                            ),
                            subtitle: Text(
                              'Chương ${bm.chapterIndex + 1} • ${(bm.scrollPercentage * 100).toStringAsFixed(1)}%',
                              style: TextStyle(
                                color: textColor.withValues(alpha: 0.6),
                                fontSize: 12,
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              onPressed: () async {
                                await BookmarkService.removeBookmark(
                                    widget.storyId, bm.id);
                                _loadBookmarks();
                              },
                            ),
                            onTap: () => widget.onBookmarkSelected(bm),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
