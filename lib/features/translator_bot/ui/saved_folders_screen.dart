import 'package:flutter/material.dart';
import '../core/models/translation_models.dart';
import '../core/storage/bot_database.dart';
import 'translated_reader_screen.dart';

class SavedFoldersScreen extends StatefulWidget {
  const SavedFoldersScreen({super.key});

  @override
  State<SavedFoldersScreen> createState() => _SavedFoldersScreenState();
}

class _SavedFoldersScreenState extends State<SavedFoldersScreen> {
  final BotDatabase _db = BotDatabase.instance;
  Map<String, List<TranslationSession>> _groupedSessions = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final data = await _db.getSavedSessionsGroupedByFolder();
    if (mounted) {
      setState(() {
        _groupedSessions = data;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.folder_special_outlined, color: Colors.pinkAccent),
            SizedBox(width: 8),
            Text('Thư mục truyện dịch'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.pinkAccent))
          : _groupedSessions.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.auto_stories_outlined, size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text(
                        'Chưa có bản dịch nào được lưu.',
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Các bản dịch bạn chọn "Lưu" khi thoát sẽ xuất hiện ở đây 🌸',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: _groupedSessions.entries.map((entry) {
                    final folderName = entry.key;
                    final chapters = entry.value;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: ExpansionTile(
                        leading: const CircleAvatar(
                          backgroundColor: Color(0xFFFFE4EC),
                          child: Icon(Icons.folder, color: Colors.pinkAccent),
                        ),
                        title: Text(
                          folderName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        subtitle: Text(
                          '${chapters.length} chương đã lưu',
                          style: const TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                        children: chapters.map((ch) {
                          return ListTile(
                            leading: const Icon(Icons.article_outlined, size: 20),
                            title: Text(ch.chapterTitle),
                            subtitle: Text(
                              'Đã dịch: ${ch.createdAt.day}/${ch.createdAt.month}/${ch.createdAt.year}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                              tooltip: 'Xóa chương này',
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Xác nhận xóa'),
                                    content: Text('Xóa bản dịch "${ch.chapterTitle}"?'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, false),
                                        child: const Text('Hủy'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, true),
                                        child: const Text('Xóa', style: TextStyle(color: Colors.red)),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  await _db.deleteSession(ch.id);
                                  _loadData();
                                }
                              },
                            ),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TranslatedReaderScreen(session: ch),
                                ),
                              ).then((_) => _loadData());
                            },
                          );
                        }).toList(),
                      ),
                    );
                  }).toList(),
                ),
    );
  }
}
