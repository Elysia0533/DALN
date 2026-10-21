import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/models/translation_models.dart';
import '../core/providers/translation_provider.dart';
import '../../../services/tts_service.dart';
import 'ellie_chat_screen.dart';

class EllieQuickTranslateSheet extends StatefulWidget {
  final String sourceText;
  final String title;

  const EllieQuickTranslateSheet({
    super.key,
    required this.sourceText,
    this.title = 'Đoạn văn',
  });

  static Future<void> show(BuildContext context, String text, {String title = 'Đoạn văn'}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EllieQuickTranslateSheet(
        sourceText: text,
        title: title,
      ),
    );
  }

  @override
  State<EllieQuickTranslateSheet> createState() => _EllieQuickTranslateSheetState();
}

class _EllieQuickTranslateSheetState extends State<EllieQuickTranslateSheet> {
  late GeminiTranslationProvider _provider;
  bool _isLoading = true;
  String _translatedText = '';
  String? _errorMessage;
  bool _isSpeaking = false;

  @override
  void initState() {
    super.initState();
    _startTranslation();
  }

  Future<void> _startTranslation() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      _provider = await GeminiTranslationProvider.fromPreferences();

      if (_provider.apiKey.isEmpty) {
        setState(() {
          _isLoading = false;
          _errorMessage =
              'Cậu chưa cài đặt Gemini API Key cho Ellie nè 🌸\n'
              'Hãy bấm nút "Cài đặt API Key" bên dưới để nhập key miễn phí từ Google AI Studio nhé!';
        });
        return;
      }

      final profile = TranslationProfile(
        id: 'quick_profile',
        title: widget.title,
        srcLang: 'auto',
        tgtLang: 'vi',
        preset: 'modern',
      );

      final seg = TranslationSegment(
        id: 'q001',
        sourceText: widget.sourceText,
      );

      final response = await _provider.translateBatch(
        segments: [seg],
        profile: profile,
        glossary: const [],
        addressRules: const [],
        rollingSummary: '',
        recentContextSegments: const [],
      );

      if (mounted) {
        setState(() {
          _isLoading = false;
          _translatedText = response.segments.isNotEmpty
              ? response.segments.first.text
              : 'Không nhận được kết quả dịch.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString().replaceFirst('StateError: ', '');
        });
      }
    }
  }

  void _toggleSpeak() {
    final textToSpeak = _translatedText.isNotEmpty ? _translatedText : widget.sourceText;
    if (textToSpeak.isEmpty) return;

    final tts = TtsService.instance;
    if (_isSpeaking) {
      tts.stop();
      setState(() => _isSpeaking = false);
    } else {
      tts.speak(textToSpeak);
      setState(() => _isSpeaking = true);
    }
  }

  @override
  void dispose() {
    if (_isSpeaking) {
      TtsService.instance.stop();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E1E24) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 10,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: 18,
            right: 18,
            top: 12,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.withAlpha(100),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Header
              Row(
                children: [
                  const CircleAvatar(
                    radius: 16,
                    backgroundColor: Color(0xFFFFD1DC),
                    child: Text('🌸', style: TextStyle(fontSize: 16)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Dịch với Ellie',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                        Text(
                          _isLoading ? 'Đang suy nghĩ & dịch...' : 'Bản dịch văn học AI',
                          style: const TextStyle(fontSize: 11.5, color: Colors.pinkAccent),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    tooltip: 'Dịch lại',
                    onPressed: _isLoading ? null : _startTranslation,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Content Area
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Source text snippet
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white.withAlpha(15) : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.withAlpha(40)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'ĐOẠN GỐC',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.sourceText,
                              style: TextStyle(
                                fontSize: 13,
                                fontStyle: FontStyle.italic,
                                color: isDark ? Colors.grey.shade300 : Colors.black87,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Translation Result or Loading or Error
                      if (_isLoading)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 36),
                          child: const Column(
                            children: [
                              CircularProgressIndicator(color: Colors.pinkAccent, strokeWidth: 2.5),
                              SizedBox(height: 16),
                              Text(
                                'Ellie đang phân tích và dịch trau chuốt...',
                                style: TextStyle(fontSize: 13, color: Colors.pinkAccent),
                              ),
                            ],
                          ),
                        )
                      else if (_errorMessage != null)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.red.shade900.withAlpha(60) : Colors.red.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.redAccent.withAlpha(120)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.info_outline, color: Colors.redAccent, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Thông báo từ Ellie 🌸',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: isDark ? Colors.red.shade200 : Colors.red.shade900,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _errorMessage!,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: isDark ? Colors.red.shade100 : Colors.red.shade900,
                                ),
                              ),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
                                icon: const Icon(Icons.tune_rounded, size: 16),
                                label: const Text('Mở Cài đặt API Key ⚙️'),
                                onPressed: () {
                                  Navigator.pop(context);
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const EllieChatScreen()),
                                  );
                                },
                              ),
                            ],
                          ),
                        )
                      else ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.pink.shade900.withAlpha(30) : const Color(0xFFFFF0F5),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.pinkAccent.withAlpha(60)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Text(
                                    'BẢN DỊCH TIẾNG VIỆT',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.pinkAccent,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    icon: const Icon(Icons.copy_rounded, size: 18, color: Colors.pinkAccent),
                                    tooltip: 'Sao chép',
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: _translatedText));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Đã sao chép bản dịch 🌸')),
                                      );
                                    },
                                  ),
                                  IconButton(
                                    icon: Icon(
                                      _isSpeaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
                                      size: 18,
                                      color: Colors.pinkAccent,
                                    ),
                                    tooltip: _isSpeaking ? 'Dừng đọc' : 'Đọc bằng giọng nói',
                                    onPressed: _toggleSpeak,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                _translatedText,
                                style: TextStyle(
                                  fontSize: 15.5,
                                  height: 1.5,
                                  color: textColor,
                                  fontWeight: FontWeight.w400,
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

              const SizedBox(height: 12),

              // Bottom Actions
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        side: BorderSide(color: Colors.grey.withAlpha(80)),
                      ),
                      icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                      label: const Text('Mở trong Ellie 🌸', style: TextStyle(fontSize: 13)),
                      onPressed: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => EllieChatScreen(
                              initialText: widget.sourceText,
                              initialTitle: widget.title,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.pinkAccent,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                    ),
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Đóng'),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
