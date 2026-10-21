import 'package:flutter/material.dart';
import '../core/engine/orchestrator.dart';
import '../core/models/translation_models.dart';
import '../core/providers/translation_provider.dart';
import '../core/storage/bot_database.dart';

class TranslatedReaderScreen extends StatefulWidget {
  final TranslationSession session;
  final TranslationProvider? provider;

  const TranslatedReaderScreen({
    super.key,
    required this.session,
    this.provider,
  });

  @override
  State<TranslatedReaderScreen> createState() => _TranslatedReaderScreenState();
}

class _TranslatedReaderScreenState extends State<TranslatedReaderScreen> {
  final BotDatabase _db = BotDatabase.instance;
  late final TranslationOrchestrator _orchestrator = TranslationOrchestrator(
    provider: widget.provider ?? GeminiTranslationProvider(),
    database: _db,
  );
  List<TranslationSegment> _segments = [];
  bool _isLoading = true;
  bool _showOriginal = false;
  double _fontSize = 17.0;

  @override
  void initState() {
    super.initState();
    _loadSegments();
  }

  Future<void> _loadSegments() async {
    final list = await _db.getSegments(widget.session.id);
    if (mounted) {
      setState(() {
        _segments = list;
        _isLoading = false;
      });
    }
  }

  Future<bool> _onWillPop() async {
    // Nếu phiên đã được lưu trước đó rồi thì chỉ việc thoát
    if (widget.session.status == SessionStatus.saved) {
      return true;
    }

    // Nếu là phiên tạm (temp), hiển thị dialog xác nhận: Mặc định KHÔNG LƯU
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.save_outlined, color: Colors.pinkAccent),
            SizedBox(width: 8),
            Text('Lưu bản dịch?'),
          ],
        ),
        content: const Text(
          'Bản dịch này hiện đang lưu tạm trên bộ nhớ máy.\nBạn có muốn lưu vĩnh viễn vào thư mục truyện dịch không?',
        ),
        actions: [
          // Nút mặc định: KHÔNG LƯU
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('Không lưu (Xóa)', style: TextStyle(color: Colors.grey)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('Lưu vào máy'),
          ),
        ],
      ),
    );

    if (action == 'save') {
      await _promptSaveDialog();
      return true;
    } else {
      // Xóa phiên tạm khỏi SQLite để dọn rác bộ nhớ
      await _db.deleteSession(widget.session.id);
      return true;
    }
  }

  Future<void> _promptSaveDialog() async {
    final folderCtrl = TextEditingController(text: widget.session.folderName);
    final titleCtrl = TextEditingController(text: widget.session.chapterTitle);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lưu vào thư mục truyện'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: folderCtrl,
              decoration: const InputDecoration(
                labelText: 'Tên bộ truyện (Thư mục)',
                hintText: 'vd: Sukasuka',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Tên chương',
                hintText: 'vd: Chương 1',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
            onPressed: () async {
              await _db.markSessionAsSaved(
                widget.session.id,
                folderName: folderCtrl.text.trim().isNotEmpty ? folderCtrl.text.trim() : 'Chưa phân loại',
                chapterTitle: titleCtrl.text.trim().isNotEmpty ? titleCtrl.text.trim() : 'Chương không tên',
              );
              widget.session.status = SessionStatus.saved;
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Xác nhận lưu'),
          ),
        ],
      ),
    );
  }

  Future<void> _openEditSegmentDialog(TranslationSegment seg) async {
    final controller = TextEditingController(
      text: seg.translatedText.isNotEmpty ? seg.translatedText : seg.sourceText,
    );
    bool isSaving = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome, color: Colors.pinkAccent, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Sửa câu dịch & Train bot',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              if (seg.sourceText.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.withAlpha(25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    seg.sourceText,
                    style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: Colors.grey),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Bản dịch tiếng Việt đã sửa',
                  hintText: 'Nhập câu dịch mượt mà hơn...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Khi bạn lưu, Ellie sẽ tự động học các thuật ngữ, tên riêng và cách xưng hô bạn đã sửa để áp dụng cho các đoạn dịch sau.',
                style: TextStyle(fontSize: 12, color: Colors.pinkAccent),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: isSaving ? null : () => Navigator.pop(ctx),
                    child: const Text('Hủy'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
                    icon: isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.psychology, size: 18),
                    label: Text(isSaving ? 'Bot đang học...' : 'Lưu & Train bot'),
                    onPressed: isSaving
                        ? null
                        : () async {
                            final newText = controller.text.trim();
                            if (newText.isEmpty) return;
                            setSheetState(() => isSaving = true);
                            try {
                              final result = await _orchestrator.learnFromUserEditAndApply(
                                session: widget.session,
                                segmentId: seg.id,
                                userEditedText: newText,
                              );
                              if (mounted) {
                                setState(() {
                                  seg.translatedText = newText;
                                  seg.state = SegmentState.edited;
                                });
                              }
                              if (ctx.mounted) Navigator.pop(ctx);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Ellie: ${result.summary}'),
                                    backgroundColor: Colors.pink[700],
                                    duration: const Duration(seconds: 4),
                                  ),
                                );
                              }
                            } catch (e) {
                              setSheetState(() => isSaving = false);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Lỗi khi lưu: $e')),
                                );
                              }
                            }
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF121212) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white.withAlpha(220) : Colors.black87;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: bgColor,
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.session.chapterTitle,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Text(
                widget.session.folderName,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: Icon(_showOriginal ? Icons.translate : Icons.format_quote),
              tooltip: _showOriginal ? 'Ẩn văn bản gốc' : 'Xem song ngữ',
              onPressed: () {
                setState(() => _showOriginal = !_showOriginal);
              },
            ),
            IconButton(
              icon: const Icon(Icons.bookmark_add_outlined),
              tooltip: 'Lưu bản dịch',
              onPressed: _promptSaveDialog,
            ),
            PopupMenuButton<double>(
              icon: const Icon(Icons.format_size),
              tooltip: 'Cỡ chữ',
              onSelected: (size) => setState(() => _fontSize = size),
              itemBuilder: (ctx) => [
                const PopupMenuItem(value: 15.0, child: Text('Nhỏ (15px)')),
                const PopupMenuItem(value: 17.0, child: Text('Vừa (17px)')),
                const PopupMenuItem(value: 20.0, child: Text('Lớn (20px)')),
                const PopupMenuItem(value: 24.0, child: Text('Rất lớn (24px)')),
              ],
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.pinkAccent))
            : _segments.isEmpty
                ? const Center(child: Text('Không có nội dung dịch'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    itemCount: _segments.length,
                    itemBuilder: (context, index) {
                      final seg = _segments[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onLongPress: () => _openEditSegmentDialog(seg),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (_showOriginal && seg.sourceText.isNotEmpty) ...[
                                        Text(
                                          seg.sourceText,
                                          style: TextStyle(
                                            fontSize: _fontSize - 3,
                                            fontStyle: FontStyle.italic,
                                            color: isDark ? Colors.white38 : Colors.black45,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                      ],
                                      Text(
                                        seg.translatedText.isNotEmpty ? seg.translatedText : seg.sourceText,
                                        style: TextStyle(
                                          fontSize: _fontSize,
                                          height: 1.65,
                                          color: seg.translatedText.isNotEmpty
                                              ? (seg.state == SegmentState.edited
                                                  ? (isDark ? Colors.cyanAccent : Colors.teal)
                                                  : textColor)
                                              : Colors.orangeAccent,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.edit_note,
                                    size: 18,
                                    color: isDark ? Colors.white24 : Colors.black26,
                                  ),
                                  tooltip: 'Sửa & Train bot',
                                  onPressed: () => _openEditSegmentDialog(seg),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
