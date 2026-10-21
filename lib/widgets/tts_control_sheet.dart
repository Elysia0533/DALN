import 'dart:math';
import 'package:flutter/material.dart';
import '../services/tts_service.dart';

class TtsControlSheet extends StatelessWidget {
  final String textContent;
  final VoidCallback? onNextChapter;

  const TtsControlSheet({
    super.key,
    required this.textContent,
    this.onNextChapter,
  });

  static void show(
    BuildContext context, {
    required String textContent,
    VoidCallback? onNextChapter,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => TtsControlSheet(
        textContent: textContent,
        onNextChapter: onNextChapter,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tts = TtsService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF141416) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subColor = isDark ? Colors.white70 : Colors.black54;

    return ListenableBuilder(
      listenable: tts,
      builder: (context, child) {
        final speedDisplay = (tts.speechRate * 200).round();
        final pitchDisplay = (tts.pitch * 100).round();

        String engineDisplay = 'Mặc định';
        if (tts.currentEngine != null) {
          if (tts.currentEngine!.contains('google')) {
            engineDisplay = 'Google (Online)';
          } else if (tts.currentEngine!.contains('samsung')) {
            engineDisplay = 'Samsung TTS';
          } else {
            engineDisplay = tts.currentEngine!;
          }
        }

        String langDisplay = 'Việt (Việt Nam)';
        if (tts.currentLanguage == 'vi-VN' || tts.currentLanguage == 'vi') {
          langDisplay = 'Việt (Việt Nam)';
        } else if (tts.currentLanguage == 'en-US' || tts.currentLanguage == 'en') {
          langDisplay = 'English (US)';
        } else {
          langDisplay = tts.currentLanguage;
        }

        String voiceDisplay = 'Mặc định';
        if (tts.currentVoice != null) {
          if (tts.currentVoice is Map) {
            voiceDisplay = tts.currentVoice['name']?.toString() ?? 'Giọng đọc 1 (Online)';
          } else {
            voiceDisplay = tts.currentVoice.toString();
          }
        }

        return Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(50),
                blurRadius: 20,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Handle
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withAlpha(100),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Header title
                  Center(
                    child: Text(
                      'Text To Speech',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Engine Row
                  _buildOptionRow(
                    label: 'Engine',
                    value: engineDisplay,
                    textColor: textColor,
                    subColor: subColor,
                    onTap: () => _pickEngine(context, tts),
                  ),
                  const SizedBox(height: 14),

                  // Ngôn ngữ Row
                  _buildOptionRow(
                    label: 'Ngôn ngữ',
                    value: langDisplay,
                    textColor: textColor,
                    subColor: subColor,
                    onTap: () => _pickLanguage(context, tts),
                  ),
                  const SizedBox(height: 14),

                  // Giọng đọc Row
                  _buildOptionRow(
                    label: 'Giọng đọc',
                    value: voiceDisplay,
                    textColor: textColor,
                    subColor: subColor,
                    onTap: () => _pickVoice(context, tts),
                  ),
                  const SizedBox(height: 14),

                  // Luồng âm thanh Row
                  _buildOptionRow(
                    label: 'Luồng âm thanh',
                    value: tts.audioStream,
                    textColor: textColor,
                    subColor: subColor,
                    onTap: () => _pickAudioStream(context, tts),
                  ),
                  const SizedBox(height: 18),

                  // Tốc độ Slider
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Tốc độ', style: TextStyle(fontSize: 15, color: textColor)),
                      Text('$speedDisplay', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: textColor)),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                          ),
                          child: Slider(
                            value: tts.speechRate.clamp(0.25, 1.0),
                            min: 0.25,
                            max: 1.0,
                            divisions: 15,
                            onChanged: (val) => tts.setSpeechRate(val),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.remove_circle_outline, color: textColor, size: 20),
                        tooltip: 'Giảm tốc độ',
                        onPressed: () {
                          final next = (tts.speechRate - 0.05).clamp(0.25, 1.0);
                          tts.setSpeechRate(next);
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.add_circle_outline, color: textColor, size: 20),
                        tooltip: 'Tăng tốc độ',
                        onPressed: () {
                          final next = (tts.speechRate + 0.05).clamp(0.25, 1.0);
                          tts.setSpeechRate(next);
                        },
                      ),
                    ],
                  ),

                  // Độ cao Slider
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Độ cao', style: TextStyle(fontSize: 15, color: textColor)),
                      Text('$pitchDisplay', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: textColor)),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                          ),
                          child: Slider(
                            value: tts.pitch.clamp(0.5, 2.0),
                            min: 0.5,
                            max: 2.0,
                            divisions: 15,
                            onChanged: (val) => tts.setPitch(val),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.remove_circle_outline, color: textColor, size: 20),
                        tooltip: 'Giảm độ cao',
                        onPressed: () {
                          final next = (tts.pitch - 0.05).clamp(0.5, 2.0);
                          tts.setPitch(next);
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.add_circle_outline, color: textColor, size: 20),
                        tooltip: 'Tăng độ cao',
                        onPressed: () {
                          final next = (tts.pitch + 0.05).clamp(0.5, 2.0);
                          tts.setPitch(next);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Nghe thử Button (Outline style like Image 2)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(color: isDark ? Colors.white30 : Colors.black26),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () {
                      final sample = textContent.isNotEmpty
                          ? textContent.substring(0, min(160, textContent.length))
                          : 'Xin chào, đây là giọng đọc thử nghiệm của ứng dụng vBook.';
                      tts.speakPreview(sample);
                    },
                    child: Text(
                      'Nghe thử',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOptionRow({
    required String label,
    required String value,
    required Color textColor,
    required Color subColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Text(
                label,
                style: TextStyle(fontSize: 15, color: textColor),
              ),
            ),
            Expanded(
              flex: 6,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(
                      value,
                      style: TextStyle(fontSize: 14, color: subColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 18, color: subColor),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _pickEngine(BuildContext context, TtsService tts) {
    if (tts.availableEngines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không tìm thấy danh sách Engine bổ sung.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Chọn TTS Engine'),
        children: tts.availableEngines.map((engine) {
          String display = engine;
          if (engine.contains('google')) display = 'Google Speech Services';
          if (engine.contains('samsung')) display = 'Samsung TTS';
          return SimpleDialogOption(
            onPressed: () {
              tts.setEngine(engine);
              Navigator.pop(ctx);
            },
            child: Text(display),
          );
        }).toList(),
      ),
    );
  }

  void _pickLanguage(BuildContext context, TtsService tts) {
    final langs = [
      {'code': 'vi-VN', 'name': 'Tiếng Việt (Việt Nam)'},
      {'code': 'en-US', 'name': 'English (United States)'},
      {'code': 'ja-JP', 'name': 'Japanese (Nhật Bản)'},
      {'code': 'zh-CN', 'name': 'Chinese (Trung Quốc)'},
      {'code': 'ko-KR', 'name': 'Korean (Hàn Quốc)'},
    ];
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Chọn ngôn ngữ'),
        children: langs.map((l) {
          return SimpleDialogOption(
            onPressed: () {
              tts.setLanguage(l['code']!);
              Navigator.pop(ctx);
            },
            child: Text(l['name']!),
          );
        }).toList(),
      ),
    );
  }

  void _pickVoice(BuildContext context, TtsService tts) {
    if (tts.availableVoices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đang dùng giọng đọc mặc định của máy.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Chọn giọng đọc (Voice)'),
        children: tts.availableVoices.map((voice) {
          String name = 'Mặc định';
          if (voice is Map) {
            name = voice['name']?.toString() ?? 'Voice';
          } else {
            name = voice.toString();
          }
          return SimpleDialogOption(
            onPressed: () {
              tts.setVoice(voice);
              Navigator.pop(ctx);
            },
            child: Text(name),
          );
        }).toList(),
      ),
    );
  }

  void _pickAudioStream(BuildContext context, TtsService tts) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Chọn luồng âm thanh'),
        children: TtsService.availableAudioStreams.map((stream) {
          return SimpleDialogOption(
            onPressed: () {
              tts.setAudioStream(stream);
              Navigator.pop(ctx);
            },
            child: Text(stream),
          );
        }).toList(),
      ),
    );
  }
}
