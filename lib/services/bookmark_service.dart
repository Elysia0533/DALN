import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/reading_progress.dart';

/// Service quản lý lưu tiến độ đọc và bookmarks
class BookmarkService {
  static const String _progressPrefix = 'rp_';     // reading progress
  static const String _bookmarkPrefix = 'bm_';     // bookmarks per story
  static const String _allBookmarksKey = 'all_bookmark_story_ids';
  static final Map<String, Timer> _saveTimers = {};

  // ═══════════════════════════════════════════════════════
  // TIẾN ĐỘ ĐỌC
  // ═══════════════════════════════════════════════════════

  /// Lưu tiến độ đọc (debounced 500ms để tránh ghi liên tục khi cuộn)
  static void saveProgress(ReadingProgress progress) {
    _saveTimers[progress.storyId]?.cancel();
    _saveTimers[progress.storyId] = Timer(
      const Duration(milliseconds: 500),
      () => _saveProgressNow(progress),
    );
  }

  /// Lưu tiến độ đọc ngay lập tức (dùng khi thoát screen)
  static Future<void> saveProgressNow(ReadingProgress progress) async {
    _saveTimers[progress.storyId]?.cancel();
    await _saveProgressNow(progress);
  }

  static Future<void> _saveProgressNow(ReadingProgress progress) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_progressPrefix${progress.storyId}',
        progress.encode(),
      );
    } catch (e) {
      debugPrint('BookmarkService: Không thể lưu tiến độ: $e');
    }
  }

  /// Lấy tiến độ đọc đã lưu
  static Future<ReadingProgress?> getProgress(String storyId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString('$_progressPrefix$storyId');
      if (encoded == null || encoded.isEmpty) return null;
      return ReadingProgress.decode(encoded);
    } catch (e) {
      debugPrint('BookmarkService: Không thể đọc tiến độ: $e');
      return null;
    }
  }

  /// Xóa tiến độ đọc
  static Future<void> clearProgress(String storyId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_progressPrefix$storyId');
    } catch (e) {
      debugPrint('BookmarkService: Không thể xóa tiến độ: $e');
    }
  }

  // ═══════════════════════════════════════════════════════
  // BOOKMARKS
  // ═══════════════════════════════════════════════════════

  /// Thêm bookmark mới
  static Future<void> addBookmark(Bookmark bookmark) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookmarks = await getBookmarks(bookmark.storyId);
      bookmarks.add(bookmark);
      await _saveBookmarksForStory(prefs, bookmark.storyId, bookmarks);
      await _trackStoryId(prefs, bookmark.storyId);
    } catch (e) {
      debugPrint('BookmarkService: Không thể thêm bookmark: $e');
    }
  }

  /// Lấy bookmarks theo truyện
  static Future<List<Bookmark>> getBookmarks(String storyId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString('$_bookmarkPrefix$storyId');
      if (encoded == null || encoded.isEmpty) return [];
      final List<dynamic> list = json.decode(encoded);
      return list.map((e) => Bookmark.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('BookmarkService: Không thể đọc bookmarks: $e');
      return [];
    }
  }

  /// Lấy TẤT CẢ bookmarks (cho màn hình quản lý)
  static Future<List<Bookmark>> getAllBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storyIds = prefs.getStringList(_allBookmarksKey) ?? [];
      final allBookmarks = <Bookmark>[];
      for (final storyId in storyIds) {
        final bookmarks = await getBookmarks(storyId);
        allBookmarks.addAll(bookmarks);
      }
      // Sắp xếp mới nhất trước
      allBookmarks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return allBookmarks;
    } catch (e) {
      debugPrint('BookmarkService: Không thể đọc tất cả bookmarks: $e');
      return [];
    }
  }

  /// Xóa bookmark
  static Future<void> removeBookmark(String storyId, String bookmarkId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookmarks = await getBookmarks(storyId);
      bookmarks.removeWhere((b) => b.id == bookmarkId);
      await _saveBookmarksForStory(prefs, storyId, bookmarks);
      if (bookmarks.isEmpty) {
        await _untrackStoryId(prefs, storyId);
      }
    } catch (e) {
      debugPrint('BookmarkService: Không thể xóa bookmark: $e');
    }
  }

  /// Cập nhật ghi chú bookmark
  static Future<void> updateBookmarkNote(
    String storyId,
    String bookmarkId,
    String note,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookmarks = await getBookmarks(storyId);
      final index = bookmarks.indexWhere((b) => b.id == bookmarkId);
      if (index != -1) {
        bookmarks[index] = bookmarks[index].copyWith(note: note);
        await _saveBookmarksForStory(prefs, storyId, bookmarks);
      }
    } catch (e) {
      debugPrint('BookmarkService: Không thể cập nhật bookmark: $e');
    }
  }

  /// Đếm tổng số bookmarks
  static Future<int> getTotalBookmarkCount() async {
    final all = await getAllBookmarks();
    return all.length;
  }

  // ═══════════════════════════════════════════════════════
  // INTERNAL
  // ═══════════════════════════════════════════════════════

  static Future<void> _saveBookmarksForStory(
    SharedPreferences prefs,
    String storyId,
    List<Bookmark> bookmarks,
  ) async {
    final encoded = json.encode(bookmarks.map((b) => b.toJson()).toList());
    await prefs.setString('$_bookmarkPrefix$storyId', encoded);
  }

  static Future<void> _trackStoryId(SharedPreferences prefs, String storyId) async {
    final ids = prefs.getStringList(_allBookmarksKey) ?? [];
    if (!ids.contains(storyId)) {
      ids.add(storyId);
      await prefs.setStringList(_allBookmarksKey, ids);
    }
  }

  static Future<void> _untrackStoryId(SharedPreferences prefs, String storyId) async {
    final ids = prefs.getStringList(_allBookmarksKey) ?? [];
    ids.remove(storyId);
    await prefs.setStringList(_allBookmarksKey, ids);
  }
}
