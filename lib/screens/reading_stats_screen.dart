import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/reading_progress.dart';
import '../models/story.dart';
import '../services/api_service.dart';

class ReadingStatsScreen extends StatefulWidget {
  const ReadingStatsScreen({super.key});

  @override
  State<ReadingStatsScreen> createState() => _ReadingStatsScreenState();
}

class _ReadingStatsScreenState extends State<ReadingStatsScreen> {
  bool _isLoading = true;
  int _totalStoriesRead = 0;
  int _totalChaptersRead = 0;
  List<ReadingProgress> _recentProgresses = [];
  List<Story> _localStories = [];

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    
    final progresses = <ReadingProgress>[];
    for (final key in keys) {
      if (key.startsWith('rp_')) {
        final encoded = prefs.getString(key);
        if (encoded != null && encoded.isNotEmpty) {
          try {
            progresses.add(ReadingProgress.decode(encoded));
          } catch (e) {
            debugPrint('Lỗi decode progress: $e');
          }
        }
      }
    }

    final historyMarkers = await ApiService.getReadingHistory();
    for (final marker in historyMarkers) {
      final exists = progresses.any((p) => p.storyId == marker.storyId);
      if (!exists) {
        progresses.add(ReadingProgress(
          storyId: marker.storyId,
          chapterIndex: marker.chapterIndex,
          scrollOffset: marker.scrollOffset,
          updatedAt: marker.updatedAt,
        ));
      }
    }

    int totalChapters = 0;
    for (final p in progresses) {
      totalChapters += (p.chapterIndex > 0 ? p.chapterIndex : 1);
    }

    progresses.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    final localStories = await ApiService.fetchPersonalStories();

    if (mounted) {
      setState(() {
        _totalStoriesRead = progresses.length;
        _totalChaptersRead = totalChapters;
        _recentProgresses = progresses;
        _localStories = localStories;
        _isLoading = false;
      });
    }
  }

  String _getStoryTitle(String storyId) {
    try {
      return _localStories.firstWhere((s) => s.id == storyId).title;
    } catch (e) {
      return 'Truyện không tên';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Thống kê đọc sách'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatCard(
                          'Tổng truyện\nđã đọc',
                          _totalStoriesRead.toString(),
                          Icons.book_rounded,
                          Colors.blue,
                          isDark,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildStatCard(
                          'Tổng chương\nđã đọc',
                          _totalChaptersRead.toString(),
                          Icons.layers_rounded,
                          Colors.purple,
                          isDark,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    'Truyện đọc gần đây',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  if (_recentProgresses.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: Text('Chưa có lịch sử đọc', style: TextStyle(color: Colors.grey)),
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _recentProgresses.length > 10 ? 10 : _recentProgresses.length, // Show up to 10
                      itemBuilder: (context, index) {
                        final progress = _recentProgresses[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          elevation: 0,
                          color: isDark ? Colors.white10 : Colors.grey.shade100,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.blue.withValues(alpha: 0.1),
                              child: const Icon(Icons.menu_book_rounded, color: Colors.blue),
                            ),
                            title: Text(_getStoryTitle(progress.storyId), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('Chương ${progress.chapterIndex} / ${progress.totalChapters}'),
                            trailing: Text(
                              '${progress.updatedAt.day}/${progress.updatedAt.month}',
                              style: TextStyle(color: isDark ? Colors.white54 : Colors.black54, fontSize: 12),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? color.withValues(alpha: 0.1) : color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 16),
          Text(
            value,
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: color),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black87),
          ),
        ],
      ),
    );
  }
}
