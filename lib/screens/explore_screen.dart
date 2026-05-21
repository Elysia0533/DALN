import 'package:flutter/material.dart';
import '../models/story.dart';
import '../services/api_service.dart';
import '../services/google_drive_service.dart';
import 'story_detail_screen.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  List<Story> _serverStories = [];
  bool _isLoading = true;
  bool _isAdmin = false;
  bool _isSearching = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadServerStories();
  }

  Future<void> _loadServerStories() async {
    setState(() => _isLoading = true);
    _serverStories = await ApiService.fetchServerStories();
    setState(() => _isLoading = false);
  }

  void _importFromDriveDialog() {
    TextEditingController urlController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Thêm Thư mục Drive vào Server'),
          content: TextField(
            controller: urlController,
            decoration: const InputDecoration(hintText: 'https://drive.google.com/...'),
          ),
          actions: [
            TextButton(
              child: const Text('Hủy'),
              onPressed: () => Navigator.pop(dialogContext),
            ),
            TextButton(
              child: const Text('Quét & Thêm'),
              onPressed: () async {
                Navigator.pop(dialogContext);
                setState(() => _isLoading = true);
                try {
                  List<Story> driveStories = await GoogleDriveService.fetchStoriesFromFolder(urlController.text);
                  await ApiService.addServerStories(driveStories);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Đã thêm ${driveStories.length} truyện từ Drive vào Server!')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Lỗi: $e')),
                    );
                  }
                }
                _loadServerStories();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
        elevation: 0,
        title: _isSearching
            ? TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Tìm kiếm truyện...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: isDark ? Colors.grey : Colors.black54),
                ),
                style: TextStyle(color: isDark ? Colors.white : Colors.black),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value.toLowerCase();
                  });
                },
              )
            : GestureDetector(
                onLongPress: () {
                  setState(() {
                    _isAdmin = !_isAdmin;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(_isAdmin ? 'Đã bật chế độ Admin' : 'Đã tắt chế độ Admin')),
                  );
                },
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.menu_book, size: 18),
                    ),
                    const SizedBox(width: 8),
                    const Text('Khám phá', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
                    const SizedBox(width: 4),
                    const Icon(Icons.keyboard_arrow_down, size: 20),
                  ],
                ),
              ),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                if (_isSearching) {
                  _isSearching = false;
                  _searchQuery = '';
                } else {
                  _isSearching = true;
                }
              });
            },
          ),
          if (!_isSearching)
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () {},
            ),
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.add_link),
              onPressed: _importFromDriveDialog,
              tooltip: 'Thêm truyện từ Drive',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Builder(
              builder: (context) {
                final displayStories = _searchQuery.isEmpty 
                    ? _serverStories 
                    : _serverStories.where((s) => s.title.toLowerCase().contains(_searchQuery)).toList();

                if (displayStories.isEmpty) {
                  return const Center(child: Text('Không tìm thấy truyện nào.'));
                }

                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _searchQuery.isNotEmpty ? 'Kết quả tìm kiếm' : 'Mới cập nhật',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            if (_searchQuery.isEmpty)
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                height: 3,
                                width: 80,
                                decoration: BoxDecoration(
                                  color: isDark ? Colors.white : Colors.black87,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      sliver: SliverGrid(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 0.54,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 16,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            Story story = displayStories[index];
                            return GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => StoryDetailScreen(story: story)),
                                );
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Container(
                                      width: double.infinity,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(6),
                                        color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
                                        image: story.iconUrl.isNotEmpty
                                            ? DecorationImage(
                                                image: NetworkImage(story.iconUrl),
                                                fit: BoxFit.cover,
                                              )
                                            : null,
                                      ),
                                      child: story.iconUrl.isEmpty
                                          ? Center(child: Icon(Icons.book, size: 40, color: isDark ? Colors.white54 : Colors.black54))
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    story.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      height: 1.2,
                                      color: isDark ? Colors.white : Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Chương mới nhất',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                          childCount: displayStories.length,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
