import 'package:flutter/material.dart';
import 'dart:io';
import '../models/story.dart';
import '../services/api_service.dart';
import '../services/google_drive_service.dart';
import 'package:path_provider/path_provider.dart';
import 'chapter_reader_screen.dart';
import 'pdf_reader_screen.dart';
import 'reading_screen.dart';

class StoryDetailScreen extends StatefulWidget {
  final Story story;

  const StoryDetailScreen({super.key, required this.story});

  @override
  State<StoryDetailScreen> createState() => _StoryDetailScreenState();
}

class _StoryDetailScreenState extends State<StoryDetailScreen> {
  bool _isDownloading = false;
  bool _descExpanded = false;
  late Story _story;

  @override
  void initState() {
    super.initState();
    _story = widget.story;
  }

  Future<void> _addToLibrary() async {
    await ApiService.importLocalStory(_story);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã thêm vào Kệ sách!')),
      );
    }
  }

  Future<void> _downloadStory() async {
    if (!_story.isFromDrive || _story.driveFileId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Truyện này không hỗ trợ tải xuống trực tiếp.')),
      );
      return;
    }
    setState(() => _isDownloading = true);
    try {
      final bytes = await GoogleDriveService.downloadFileBytes(_story.driveFileId);
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${_story.title}');
      await file.writeAsBytes(bytes);
      Story updatedStory = _story.copyWith(localPath: file.path, isLocal: true);
      await ApiService.importLocalStory(updatedStory);
      await ApiService.updateLocalStory(updatedStory);
      setState(() => _story = updatedStory);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tải xuống thành công!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi tải xuống: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  void _startReading() {
    final localPath = _story.localPath;
    if (localPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng tải xuống truyện trước khi đọc.')),
      );
      return;
    }
    if (localPath.endsWith('.pdf')) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => PdfReaderScreen(story: _story)));
    } else if (localPath.endsWith('.epub')) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChapterReaderScreen(story: _story)));
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => ReadingScreen(story: _story)));
    }
  }

  Widget _buildCoverImage(double width, double height) {
    final iconUrl = _story.iconUrl;
    ImageProvider? imageProvider;
    if (iconUrl.isNotEmpty) {
      if (iconUrl.startsWith('http')) {
        imageProvider = NetworkImage(iconUrl);
      } else if (File(iconUrl).existsSync()) {
        imageProvider = FileImage(File(iconUrl));
      }
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey.shade800,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
        image: imageProvider != null
            ? DecorationImage(image: imageProvider, fit: BoxFit.cover)
            : null,
      ),
      child: imageProvider == null
          ? const Center(child: Icon(Icons.menu_book_rounded, size: 64, color: Colors.white38))
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ─── Sliver App Bar with blurred cover ───
          SliverAppBar(
            expandedHeight: size.height * 0.38,
            pinned: true,
            stretch: true,
            backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
              ),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [StretchMode.zoomBackground],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  // Blurred bg cover
                  Builder(builder: (_) {
                    final iconUrl = _story.iconUrl;
                    ImageProvider? ip;
                    if (iconUrl.isNotEmpty) {
                      if (iconUrl.startsWith('http')) {
                        ip = NetworkImage(iconUrl);
                      } else if (File(iconUrl).existsSync()) {
                        ip = FileImage(File(iconUrl));
                      }
                    }
                    return ip != null
                        ? Image(image: ip, fit: BoxFit.cover)
                        : Container(color: const Color(0xFF2C2C2C));
                  }),
                  // Gradient overlay
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.15),
                          Colors.black.withValues(alpha: 0.75),
                        ],
                      ),
                    ),
                  ),
                  // Cover + title at bottom
                  Positioned(
                    bottom: 20,
                    left: 20,
                    right: 20,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _buildCoverImage(90, 130),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _story.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
                              _buildInfoChip(
                                _story.localPath.isNotEmpty
                                    ? _story.localPath.split('.').last.toUpperCase()
                                    : 'EPUB',
                                Colors.white.withValues(alpha: 0.25),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ─── Action buttons ───
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: FilledButton.icon(
                      onPressed: _startReading,
                      icon: const Icon(Icons.menu_book_rounded, size: 20),
                      label: Text(
                        _story.savedChapterIndex > 0
                            ? 'Đọc tiếp (Ch.${_story.savedChapterIndex + 1})'
                            : 'Đọc ngay',
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (_story.isFromDrive && _story.localPath.isEmpty) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isDownloading ? null : _downloadStory,
                        icon: _isDownloading
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.download_rounded, size: 20),
                        label: const Text('Tải về'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ] else if (!_story.isLocal) ...[
                    IconButton.outlined(
                      onPressed: _addToLibrary,
                      icon: const Icon(Icons.library_add_rounded),
                      tooltip: 'Thêm vào kệ',
                    ),
                  ],
                ],
              ),
            ),
          ),

          // ─── Description Section ───
          if (_story.description.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 4, height: 20,
                          decoration: BoxDecoration(
                            color: Theme.of(context).primaryColor,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text('Giới thiệu',
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    AnimatedCrossFade(
                      duration: const Duration(milliseconds: 300),
                      crossFadeState: _descExpanded
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                      firstChild: Text(
                        _story.description,
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.6,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                      secondChild: Text(
                        _story.description,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.6,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _descExpanded = !_descExpanded),
                      child: Text(_descExpanded ? 'Thu gọn ▲' : 'Xem thêm ▼'),
                    ),
                  ],
                ),
              ),
            ),

          // ─── Bottom padding ───
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }

  Widget _buildInfoChip(String label, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500)),
    );
  }
}
