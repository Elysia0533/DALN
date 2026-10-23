import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:epubx/epubx.dart' as epubx;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/engine/orchestrator.dart';
import '../core/models/translation_models.dart';
import '../core/providers/translation_provider.dart';
import 'glossary_editor_sheet.dart';
import 'saved_folders_screen.dart';
import 'translated_reader_screen.dart';

class EllieChatScreen extends StatefulWidget {
  final String? initialText;
  final String? initialTitle;

  const EllieChatScreen({
    super.key,
    this.initialText,
    this.initialTitle,
  });

  @override
  State<EllieChatScreen> createState() => _EllieChatScreenState();
}

class _ChatMessage {
  final String text;
  final bool isUser;
  final TranslationSession? attachedSession;
  final List<TranslationSegment>? previewSegments;
  final double? progress;

  _ChatMessage({
    required this.text,
    required this.isUser,
    this.attachedSession,
    this.previewSegments,
    this.progress,
  });

  _ChatMessage copyWith({
    String? text,
    bool? isUser,
    TranslationSession? attachedSession,
    List<TranslationSegment>? previewSegments,
    double? progress,
  }) {
    return _ChatMessage(
      text: text ?? this.text,
      isUser: isUser ?? this.isUser,
      attachedSession: attachedSession ?? this.attachedSession,
      previewSegments: previewSegments ?? this.previewSegments,
      progress: progress ?? this.progress,
    );
  }
}

class _EllieChatScreenState extends State<EllieChatScreen> {
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  late final TranslationOrchestrator _orchestrator;
  late final GeminiTranslationProvider _provider;

  final List<_ChatMessage> _messages = [];
  bool _isProcessing = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _provider = GeminiTranslationProvider(modelName: 'gemini-3.8-flash');
    _orchestrator = TranslationOrchestrator(provider: _provider);

    _loadSavedConfig().then((_) {
      if (widget.initialText != null && widget.initialText!.trim().isNotEmpty) {
        _startNewTranslationSession(
          widget.initialText!.trim(),
          widget.initialTitle ?? 'Văn bản cần dịch',
        );
      }
    });

    // Lời chào mở đầu lấy cảm hứng từ phong cách Elysia
    _messages.add(
      _ChatMessage(
        text: 'Chào bạn thân mến! Mình là Ellie đây! 🌸\n\n'
            'Hôm nay cậu muốn dịch tác phẩm thú vị nào cùng Ellie không? '
            'Cậu có thể dán đoạn văn, gửi link hoặc chọn chức năng bên dưới nhé!\n'
            'Nếu cậu chưa cài đặt Gemini API Key, hãy bấm vào biểu tượng ⚙️ ở góc trên để cấu hình nha~ ✨',
        isUser: false,
      ),
    );
  }

  Future<void> _loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    var model = prefs.getString('ellie_gemini_model') ?? 'gemini-3.8-flash';
    // Tự động nâng cấp nếu trước đó lưu các model cũ đã ngừng hỗ trợ (1.0, 1.5, 2.0, 2.5)
    if (model.contains('1.0') ||
        model.contains('1.5') ||
        model.contains('2.0') ||
        model.contains('2.5') ||
        model == 'gemini-pro') {
      model = 'gemini-3.8-flash';
      await prefs.setString('ellie_gemini_model', model);
    }
    final apiKey = await GeminiTranslationProvider.resolveEffectiveKey(
      candidateKey: prefs.getString('ellie_gemini_api_key'),
    );
    _provider.modelName = model;
    _provider.apiKey = apiKey;
    if (mounted) setState(() {});
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handlePickFile() async {
    if (_isProcessing) return;
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub', 'md', 'json', 'pdf'],
      );

      if (result == null || result.files.isEmpty || result.files.single.path == null) {
        return;
      }

      final file = File(result.files.single.path!);
      final fileName = result.files.single.name;
      final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';

      setState(() => _isProcessing = true);

      String content = '';
      if (ext == 'epub') {
        try {
          final bytes = await file.readAsBytes();
          final book = await epubx.EpubReader.readBook(bytes);
          final sb = StringBuffer();
          if (book.Chapters != null) {
            for (final ch in book.Chapters!) {
              final html = ch.HtmlContent ?? '';
              final plain = html
                  .replaceAll(RegExp(r'<[^>]*>'), ' ')
                  .replaceAll('&nbsp;', ' ')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim();
              if (plain.isNotEmpty) {
                sb.writeln(plain);
                sb.writeln();
              }
            }
          }
          content = sb.toString().trim();
        } catch (e) {
          throw Exception('Không thể đọc file EPUB: $e');
        }
      } else if (ext == 'pdf') {
        try {
          final bytes = await file.readAsBytes();
          final document = PdfDocument(inputBytes: bytes);
          final extractor = PdfTextExtractor(document);
          content = extractor.extractText();
          document.dispose();
          if (content.trim().isEmpty) {
            throw Exception(
              'Tệp PDF này không chứa văn bản số (có thể là tài liệu scan dạng ảnh chụp). Ellie chỉ hỗ trợ dịch PDF có chứa văn bản ký tự số.',
            );
          }
        } catch (e) {
          throw Exception('Không thể trích xuất văn bản từ PDF: $e');
        }
      } else {
        try {
          content = await file.readAsString();
        } catch (_) {
          final bytes = await file.readAsBytes();
          content = String.fromCharCodes(bytes);
        }
      }

      if (content.trim().isEmpty) {
        throw Exception('Tệp trống hoặc không chứa văn bản đọc được.');
      }

      final fileSizeKb = (await file.length() / 1024).toStringAsFixed(1);
      final displayTitle = fileName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');

      setState(() {
        _messages.add(
          _ChatMessage(
            text: '📎 Đã đính kèm tệp: **$fileName** ($fileSizeKb KB)',
            isUser: true,
          ),
        );
      });
      _scrollToBottom();

      await _startNewTranslationSession(content, displayTitle);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi nhập tệp: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _handleSendMessage() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _isProcessing) return;

    if (_provider.apiKey.isEmpty) {
      await _loadSavedConfig();
    }

    _textCtrl.clear();
    setState(() {
      _messages.add(_ChatMessage(text: text, isUser: true));
      _isProcessing = true;
    });
    _scrollToBottom();

    // Nếu văn bản dài (> 120 ký tự), Ellie hiểu đây là đoạn truyện cần dịch!
    if (text.length > 120) {
      await _startNewTranslationSession(text, 'Đoạn văn tự do');
    } else {
      // Nếu là câu trò chuyện thông thường, Ellie sẽ phản hồi theo phong cách thân thiện
      try {
        final history = _messages
            .where((m) => m.attachedSession == null)
            .map((m) => {'role': m.isUser ? 'user' : 'model', 'text': m.text})
            .toList();

        final reply = await _provider.chatWithEllie(
          userMessage: text,
          conversationHistory: history,
        );

        if (mounted) {
          setState(() {
            _messages.add(_ChatMessage(text: reply, isUser: false));
            _isProcessing = false;
          });
          _scrollToBottom();
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _messages.add(
              _ChatMessage(
                text: 'Úi, dường như có chút trục trặc khi kết nối với Ellie rồi \n($e)\n\n Cậu có thể bấm biểu tượng ⚙️ góc trên để kiểm tra Model hoặc nhập API Key nhé!',
                isUser: false,
              ),
            );
            _isProcessing = false;
          });
        }
      }
    }
  }

  Future<void> _startNewTranslationSession(String rawText, String title) async {
    try {
      final session = await _orchestrator.createSessionFromText(
        text: rawText,
        title: title,
      );

      setState(() {
        _messages.add(
          _ChatMessage(
            text: 'Ellie đã nhận được văn bản của cậu rồi nè! \n'
                'Độ dài: khoảng ${rawText.length} ký tự.\n\n'
                ' Cậu có thể tùy chỉnh tên nhân vật trước, hoặc bấm **Dịch thử (Preview)** để xem bản dịch mẫu trước nha!',
            isUser: false,
            attachedSession: session,
          ),
        );
        _isProcessing = false;
      });
      _scrollToBottom();
    } catch (e) {
      setState(() {
        _messages.add(_ChatMessage(text: 'Có lỗi khi nạp văn bản: $e', isUser: false));
        _isProcessing = false;
      });
    }
  }

  Future<void> _onPreviewClicked(TranslationSession session, int msgIndex) async {
    setState(() => _isProcessing = true);
    try {
      final previews = await _orchestrator.translatePreview(session: session);
      setState(() {
        _messages[msgIndex] = _messages[msgIndex].copyWith(
          previewSegments: previews,
        );
        _messages.add(
          _ChatMessage(
            text: 'Đây là bản dịch mẫu mở đầu nè \n'
                'Cậu xem qua có ưng ý không nhé? Nếu muốn chỉnh lại cách xưng hô hay từ ngữ, cậu có thể nhấn vào đoạn để sửa trực tiếp hoặc để lại lời nhắn cho Ellie nha!',
            isUser: false,
            attachedSession: session,
          ),
        );
        _isProcessing = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi dịch thử ($e). Hãy thử đổi model trong ⚙️ nhé!')),
      );
    }
  }

  Future<void> _onTranslateAllClicked(TranslationSession session, int msgIndex) async {
    setState(() => _isProcessing = true);
    try {
      final stream = _orchestrator.translateRemaining(session: session);
      await for (final progress in stream) {
        if (!mounted) return;
        setState(() {
          _messages[msgIndex] = _messages[msgIndex].copyWith(progress: progress);
        });
      }

      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _messages.add(
          _ChatMessage(
            text: 'Tadaaa~! Toàn bộ chương truyện đã được dịch hoàn tất rồi! \n'
                'Cậu bấm nút bên dưới để mở màn hình đọc truyện nhé. Đọc xong nếu không muốn lưu thì cứ thoát ra, Ellie sẽ không lưu về máy tránh tốn bộ nhớ đâu nè~',
            isUser: false,
            attachedSession: session,
          ),
        );
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi dịch ($e). Hãy thử đổi model trong ⚙️ nhé!')),
      );
    }
  }

  Future<void> _showSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    String currentModel = _provider.modelName;
    final keyCtrl = TextEditingController(text: _provider.apiKey);
    final customModelCtrl = TextEditingController(text: currentModel);

    final defaultModels = [
      {'id': 'gemini-3.8-flash', 'name': 'Gemini 3.8 Flash (Khuyên dùng - Nhanh, chuẩn nhất)'},
      {'id': 'gemini-3.5-flash', 'name': 'Gemini 3.5 Flash (Bản chuẩn ổn định)'},
      {'id': 'gemini-3.5-flash-lite', 'name': 'Gemini 3.5 Flash Lite (Tiết kiệm quota)'},
      {'id': 'gemini-flash-latest', 'name': 'Gemini Flash Latest (Tự cập nhật bản mới nhất)'},
    ];

    List<Map<String, String>> dynamicModels = List.from(defaultModels);
    bool isTesting = false;
    bool isFetchingModels = false;
    String? testStatusMessage;
    bool? testSuccess;
    bool obscureKey = true;

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          final chosenModel = currentModel == 'custom'
              ? customModelCtrl.text.trim()
              : currentModel;

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.tune_rounded, color: Colors.pinkAccent),
                SizedBox(width: 8),
                Text('Cấu hình Model AI ⚙️', style: TextStyle(fontSize: 18)),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Gemini API Key:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Lấy API key hoàn toàn miễn phí từ Google AI Studio (aistudio.google.com).',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: keyCtrl,
                      obscureText: obscureKey,
                      decoration: InputDecoration(
                        labelText: 'API Key (AIzaSy...)',
                        hintText: 'Dán API key Google vào đây',
                        border: const OutlineInputBorder(),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                obscureKey ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                size: 18,
                              ),
                              onPressed: () => setDialogState(() => obscureKey = !obscureKey),
                            ),
                            if (keyCtrl.text.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  keyCtrl.clear();
                                  setDialogState(() {});
                                },
                              ),
                          ],
                        ),
                      ),
                      onChanged: (_) => setDialogState(() {
                        testStatusMessage = null;
                        testSuccess = null;
                      }),
                    ),
                    if (keyCtrl.text.trim().isNotEmpty &&
                        !GeminiTranslationProvider.isValidKeyFormat(keyCtrl.text.trim())) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.info_outline, size: 14, color: Colors.orange.shade700),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Lưu ý: API Key của Google AI Studio thường bắt đầu bằng "AIzaSy" (39 ký tự).',
                              style: TextStyle(fontSize: 11, color: Colors.orange.shade700),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.open_in_new, size: 14, color: Colors.pinkAccent),
                        label: const Text(
                          'Lấy key miễn phí: aistudio.google.com',
                          style: TextStyle(fontSize: 11.5, color: Colors.pinkAccent),
                        ),
                        onPressed: () {
                          Clipboard.setData(const ClipboardData(text: 'https://aistudio.google.com/app/apikey'));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Đã copy link Google AI Studio: https://aistudio.google.com/app/apikey')),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Chọn phiên bản mô hình Gemini:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: dynamicModels.any((m) => m['id'] == currentModel)
                          ? currentModel
                          : 'custom',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      items: [
                        ...dynamicModels.map((m) {
                          return DropdownMenuItem(
                            value: m['id'],
                            child: Text(m['name']!, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                          );
                        }),
                        const DropdownMenuItem(
                          value: 'custom',
                          child: Text('Tự nhập model khác...', style: TextStyle(fontSize: 13)),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() {
                            currentModel = val;
                            if (val != 'custom') customModelCtrl.text = val;
                            testStatusMessage = null;
                            testSuccess = null;
                          });
                        }
                      },
                    ),
                    if (currentModel == 'custom' || !dynamicModels.any((m) => m['id'] == currentModel)) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: customModelCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Tên model tùy chỉnh',
                          hintText: 'vd: gemini-3.8-flash',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    // Nút đồng bộ model từ Key
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: isFetchingModels
                            ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.sync, size: 14),
                        label: Text(
                          isFetchingModels ? 'Đang tải model...' : 'Đồng bộ model từ Key của bạn',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: isFetchingModels
                            ? null
                            : () async {
                                final key = keyCtrl.text.trim();
                                if (key.isEmpty) {
                                  setDialogState(() {
                                    testSuccess = false;
                                    testStatusMessage = 'Vui lòng nhập API Key trước khi đồng bộ model!';
                                  });
                                  return;
                                }
                                setDialogState(() => isFetchingModels = true);
                                try {
                                  final models = await _provider.fetchAvailableModels(apiKeyToUse: key);
                                  setDialogState(() {
                                    isFetchingModels = false;
                                    if (models.isNotEmpty) {
                                      dynamicModels = models.map((m) => {'id': m, 'name': m}).toList();
                                      if (!dynamicModels.any((m) => m['id'] == currentModel)) {
                                        currentModel = dynamicModels.first['id']!;
                                      }
                                      testSuccess = true;
                                      testStatusMessage = 'Đã tải ${models.length} model khả dụng từ tài khoản của bạn! 🌸';
                                    }
                                  });
                                } catch (e) {
                                  setDialogState(() {
                                    isFetchingModels = false;
                                    testSuccess = false;
                                    testStatusMessage = e.toString().replaceFirst('StateError: ', '');
                                  });
                                }
                              },
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Nút kiểm tra kết nối
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.pinkAccent,
                          side: const BorderSide(color: Colors.pinkAccent),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        icon: isTesting
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.pinkAccent))
                            : const Icon(Icons.bolt_rounded, size: 18),
                        label: Text(isTesting ? 'Đang kiểm tra kết nối...' : 'Kiểm tra kết nối API Key'),
                        onPressed: isTesting
                            ? null
                            : () async {
                                final key = keyCtrl.text.trim();
                                final model = (chosenModel.isNotEmpty ? chosenModel : 'gemini-3.8-flash');
                                setDialogState(() {
                                  isTesting = true;
                                  testStatusMessage = null;
                                  testSuccess = null;
                                });
                                try {
                                  final result = await _provider.testConnection(
                                    testApiKey: key,
                                    testModelName: model,
                                  );
                                  setDialogState(() {
                                    isTesting = false;
                                    testSuccess = true;
                                    testStatusMessage = result;
                                  });
                                } catch (e) {
                                  setDialogState(() {
                                    isTesting = false;
                                    testSuccess = false;
                                    testStatusMessage = e.toString().replaceFirst('StateError: ', '');
                                  });
                                }
                              },
                      ),
                    ),

                    if (testStatusMessage != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: (testSuccess == true)
                              ? (isDark ? Colors.green.shade900.withAlpha(80) : Colors.green.shade50)
                              : (isDark ? Colors.red.shade900.withAlpha(80) : Colors.red.shade50),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: (testSuccess == true) ? Colors.green : Colors.redAccent,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              (testSuccess == true) ? Icons.check_circle_outline : Icons.error_outline,
                              color: (testSuccess == true) ? Colors.green : Colors.redAccent,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                testStatusMessage!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: (testSuccess == true)
                                      ? (isDark ? Colors.green.shade200 : Colors.green.shade900)
                                      : (isDark ? Colors.red.shade200 : Colors.red.shade900),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Hủy'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
                onPressed: () async {
                  final chosen = currentModel == 'custom'
                      ? customModelCtrl.text.trim()
                      : currentModel;
                  final cleanModel = chosen.isNotEmpty ? chosen : 'gemini-3.8-flash';
                  final cleanKey = keyCtrl.text.trim();

                  await prefs.setString('ellie_gemini_model', cleanModel);
                  await prefs.setString('ellie_gemini_api_key', cleanKey);

                  setState(() {
                    _provider.modelName = cleanModel;
                    _provider.apiKey = cleanKey;
                  });

                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Đã lưu cấu hình: $cleanModel 🌸')),
                    );
                  }
                },
                child: const Text('Lưu cấu hình'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _promptPasteDialog() async {
    final titleCtrl = TextEditingController(text: 'Đoạn văn ${DateTime.now().hour}h${DateTime.now().minute}');
    final contentCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dán văn bản cần dịch'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: 'Tên chương / Đoạn'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentCtrl,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Nội dung gốc',
                    hintText: 'Dán đoạn truyện tiếng Anh, Trung, Nhật... vào đây',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
            onPressed: () {
              if (contentCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx);
              _startNewTranslationSession(contentCtrl.text.trim(), titleCtrl.text.trim());
            },
            child: const Text('Bắt đầu dịch'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const CircleAvatar(
              backgroundColor: Color(0xFFFFD1DC),
              child: Text('🌸', style: TextStyle(fontSize: 18)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Ellie',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Mô hình: ${_provider.modelName}',
                    style: const TextStyle(fontSize: 11, color: Colors.pinkAccent),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Cài đặt Model AI & Key',
            onPressed: _showSettingsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.folder_special_outlined),
            tooltip: 'Thư mục truyện đã dịch',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SavedFoldersScreen()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Quick Action Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: isDark ? Colors.grey[900] : Colors.pink[50],
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.paste_rounded, size: 16, color: Colors.pinkAccent),
                    label: const Text('Dán văn bản'),
                    onPressed: _promptPasteDialog,
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.tune_rounded, size: 16, color: Colors.pinkAccent),
                    label: Text('Model: ${_provider.modelName}'),
                    onPressed: _showSettingsDialog,
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.folder_open, size: 16, color: Colors.pinkAccent),
                    label: const Text('Truyện đã lưu'),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SavedFoldersScreen()),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),

          // Message List
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _buildMessageItem(msg, index, isDark);
              },
            ),
          ),

          if (_isProcessing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: LinearProgressIndicator(color: Colors.pinkAccent),
            ),

          // Chat Input Field
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file_rounded, color: Colors.pinkAccent),
                    tooltip: 'Đính kèm tệp từ máy (.txt, .epub, .md)',
                    onPressed: _isProcessing ? null : _handlePickFile,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Nhắn với Ellie hoặc dán đoạn văn vào đây...',
                        border: InputBorder.none,
                      ),
                      onSubmitted: (_) => _handleSendMessage(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send_rounded, color: Colors.pinkAccent),
                    onPressed: _handleSendMessage,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageItem(_ChatMessage msg, int index, bool isDark) {
    if (msg.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.pinkAccent,
            borderRadius: BorderRadius.circular(16).copyWith(bottomRight: Radius.zero),
          ),
          child: Text(
            msg.text,
            style: const TextStyle(color: Colors.white, fontSize: 14.5),
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E24) : Colors.white,
          borderRadius: BorderRadius.circular(16).copyWith(topLeft: Radius.zero),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(isDark ? 50 : 15),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              msg.text,
              style: TextStyle(
                fontSize: 14.5,
                height: 1.5,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),

            // Nếu có phiên dịch đính kèm
            if (msg.attachedSession != null) ...[
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 6),
              _buildSessionActions(msg.attachedSession!, msg, index),
            ],

            // Nếu có kết quả Preview
            if (msg.previewSegments != null && msg.previewSegments!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[850] : Colors.pink[50],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('🔍 Đoạn dịch thử (Preview):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),
                    ...msg.previewSegments!.map((seg) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            seg.translatedText.isNotEmpty ? seg.translatedText : seg.sourceText,
                            style: const TextStyle(fontSize: 13.5, height: 1.4),
                          ),
                        )),
                  ],
                ),
              ),
            ],

            // Thanh tiến trình dịch toàn bộ nếu đang chạy
            if (msg.progress != null && msg.progress! < 1.0) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: msg.progress,
                color: Colors.pinkAccent,
                backgroundColor: Colors.pink.withAlpha(30),
              ),
              const SizedBox(height: 4),
              Text('Đang dịch: ${(msg.progress! * 100).toInt()}%...', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSessionActions(TranslationSession session, _ChatMessage msg, int index) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.tune, size: 16, color: Colors.pinkAccent),
          label: const Text('Cấu hình tên & xưng hô'),
          onPressed: () {
            GlossaryEditorSheet.show(
              context,
              profileId: session.profileId,
              storyTitle: session.chapterTitle,
            );
          },
        ),
        if (msg.previewSegments == null)
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
            icon: const Icon(Icons.remove_red_eye, size: 16),
            label: const Text('Dịch thử 1 đoạn (Preview)'),
            onPressed: () => _onPreviewClicked(session, index),
          ),
        if (msg.previewSegments != null && (msg.progress == null || msg.progress! < 1.0))
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('Duyệt & Dịch toàn bộ 🚀'),
            onPressed: () => _onTranslateAllClicked(session, index),
          ),
        if (msg.progress != null && msg.progress! >= 1.0)
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.teal),
            icon: const Icon(Icons.menu_book, size: 16),
            label: const Text('Đọc bản dịch ngay 📖'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TranslatedReaderScreen(
                    session: session,
                    provider: _provider,
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
