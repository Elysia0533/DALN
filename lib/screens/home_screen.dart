import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../models/story.dart';
import '../services/api_service.dart';
import '../theme/theme_provider.dart';
import 'story_detail_screen.dart';
import 'explore_screen.dart';
import 'community_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  List<Story> _personalStories = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStories();
  }

  Future<void> _loadStories() async {
    setState(() => _isLoading = true);
    _personalStories = await ApiService.fetchPersonalStories();
    setState(() => _isLoading = false);
  }

  void _showSettingsBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Cài đặt',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Nhập từ máy'),
                    onPressed: () {
                      Navigator.pop(context);
                      _importStory();
                    },
                  ),
                ],
              ),
              const Divider(),
              ListTile(
                title: const Text('Kiểu kệ sách'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.grid_view),
                    SizedBox(width: 8),
                    Icon(Icons.list),
                  ],
                ),
              ),
              ListTile(
                title: const Text('Cột'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(icon: const Icon(Icons.remove), onPressed: () {}),
                    const Text('2'),
                    IconButton(icon: const Icon(Icons.add), onPressed: () {}),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _importStory() async {
    FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub', 'pdf', 'txt'],
    );

    if (result != null && result.files.single.path != null) {
      final srcPath = result.files.single.path!;
      final fileName = result.files.single.name;
      final extension = result.files.single.extension ?? '';

      // Copy file vào thư mục ứng dụng để tránh mất đường dẫn tạm thời
      String savedPath = srcPath;
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final uuid = const Uuid().v4();
        final destFile = File('${appDir.path}/${uuid}_$fileName');
        await File(srcPath).copy(destFile.path);
        savedPath = destFile.path;
      } catch (_) {
        savedPath = srcPath; // fallback nếu copy thất bại
      }

      String displayTitle = fileName.replaceAll(RegExp(r'\.(epub|pdf|txt)$', caseSensitive: false), '');
      String coverPath = '';
      String description = '';

      if (extension.toLowerCase() == 'epub') {
        try {
          final metadata = await ApiService.extractEpubMetadata(savedPath);
          if (metadata['title'] != null && metadata['title']!.isNotEmpty) {
            displayTitle = metadata['title']!;
          }
          if (metadata['coverPath'] != null && metadata['coverPath']!.isNotEmpty) {
            coverPath = metadata['coverPath']!;
          }
          if (metadata['description'] != null) {
            description = metadata['description']!;
          }
        } catch (e) {
          debugPrint('Không thể đọc metadata EPUB: $e');
        }
      }

      Story newStory = Story(
        id: const Uuid().v4(),
        title: displayTitle,
        description: description,
        localPath: savedPath,
        isLocal: true,
        iconUrl: coverPath,
      );

      if (extension.toLowerCase() == 'txt') {
        newStory = Story(
          id: newStory.id,
          title: displayTitle,
          content: await File(savedPath).readAsString(),
          localPath: savedPath,
          isLocal: true,
          iconUrl: coverPath,
        );
      }

      await ApiService.importLocalStory(newStory);
      if (mounted) _loadStories(); // Refresh
    }
  }

  Future<void> _openStory(Story story) async {
    // Always go through StoryDetailScreen first
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StoryDetailScreen(story: story)),
    );
    // Refresh library after returning (user may have read progress updated)
    _loadStories();
  }

  Widget _buildLibraryTab() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_personalStories.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_books, size: 80, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text(
              'Thư viện trống',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Hãy sang tab Khám phá để tìm truyện!',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => setState(() => _currentIndex = 1),
              child: const Text('Đi đến Khám phá'),
            )
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          margin: const EdgeInsets.all(16.0),
          height: 120,
          decoration: BoxDecoration(
            color: Colors.green.shade800,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(width: 80, color: Colors.grey),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Text(
                        'Cải Tạo Ác Nữ - Thông báo',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        maxLines: 2,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Bản Bìa Hoàn Thiện 90.0%',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              )
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.65,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            itemCount: _personalStories.length,
            itemBuilder: (context, index) {
              Story story = _personalStories[index];
              return GestureDetector(
                onTap: () => _openStory(story),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.grey.shade800,
                              image: (story.iconUrl.isNotEmpty && (story.iconUrl.startsWith('http') || File(story.iconUrl).existsSync()))
                                  ? DecorationImage(
                                      image: story.iconUrl.startsWith('http') 
                                          ? NetworkImage(story.iconUrl) as ImageProvider
                                          : FileImage(File(story.iconUrl)),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child: (story.iconUrl.isEmpty || (!story.iconUrl.startsWith('http') && !File(story.iconUrl).existsSync()))
                                ? const Center(child: Icon(Icons.insert_drive_file, size: 50, color: Colors.white54))
                                : null,
                          ),
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(4.0),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                              ),
                              child: const Text(
                                '100% Đã đọc',
                                style: TextStyle(color: Colors.white, fontSize: 10),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      story.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: _currentIndex == 0 ? AppBar(
        title: const Text('Kệ sách'),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showSettingsBottomSheet(context),
          ),
          IconButton(
            icon: Icon(themeProvider.themeMode == ThemeMode.dark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () => themeProvider.toggleTheme(),
          )
        ],
      ) : null,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _buildLibraryTab(),
          const ExploreScreen(),
          const CommunityScreen(),
          const ProfileScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          setState(() {
            _currentIndex = i;
            if (i == 0) {
              _loadStories();
            }
          });
        },
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.library_books), label: 'Kệ sách'),
          BottomNavigationBarItem(icon: Icon(Icons.explore), label: 'Khám phá'),
          BottomNavigationBarItem(icon: Icon(Icons.forum), label: 'Cộng đồng'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Cá nhân'),
        ],
      ),
    );
  }
}
