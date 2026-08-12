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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: tts,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header Drag Handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Title Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.settings_voice_rounded, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          '⚙️ Cài đặt giọng đọc TTS',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(height: 20),

                // Language Selector
                Text(
                  'Ngôn ngữ:',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: tts.currentLanguage,
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  isExpanded: true,
                  items: ['vi-VN', 'en-US', 'ja-JP', 'zh-CN', 'fr-FR', 'ko-KR']
                      .map((lang) => DropdownMenuItem(
                            value: lang,
                            child: Text(lang),
                          ))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) tts.setLanguage(val);
                  },
                ),
                const SizedBox(height: 16),

                // Voice Selector
                if (tts.availableVoices.isNotEmpty) ...[
                  Text(
                    'Giọng đọc (Voice):',
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<dynamic>(
                    initialValue: tts.currentVoice ?? (tts.availableVoices.isNotEmpty ? tts.availableVoices.first : null),
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    isExpanded: true,
                    items: tts.availableVoices.map((voice) {
                      String label = 'Voice';
                      if (voice is Map) {
                        final name = voice['name']?.toString() ?? 'Default';
                        final locale = voice['locale']?.toString() ?? '';
                        label = '$name ($locale)';
                      } else {
                        label = voice.toString();
                      }
                      return DropdownMenuItem<dynamic>(
                        value: voice,
                        child: Text(label, overflow: TextOverflow.ellipsis),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) tts.setVoice(val);
                    },
                  ),
                  const SizedBox(height: 16),
                ],

                // TTS Engine Selector
                if (tts.availableEngines.isNotEmpty) ...[
                  Text(
                    'TTS Engine:',
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: tts.currentEngine != null && tts.availableEngines.contains(tts.currentEngine)
                        ? tts.currentEngine
                        : (tts.availableEngines.isNotEmpty ? tts.availableEngines.first : null),
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    isExpanded: true,
                    items: tts.availableEngines.map((engine) {
                      String displayName = engine;
                      if (engine.contains('google')) {
                        displayName = 'Google Speech Services';
                      } else if (engine.contains('samsung')) {
                        displayName = 'Samsung TTS Engine';
                      }
                      return DropdownMenuItem<String>(
                        value: engine,
                        child: Text(displayName, overflow: TextOverflow.ellipsis),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) tts.setEngine(val);
                    },
                  ),
                  const SizedBox(height: 16),
                ],

                // Audio Stream Selector
                Text(
                  'Luồng phát âm thanh (Audio Stream):',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: tts.audioStream,
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  isExpanded: true,
                  items: TtsService.availableAudioStreams
                      .map((stream) => DropdownMenuItem(
                            value: stream,
                            child: Text(stream),
                          ))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) tts.setAudioStream(val);
                  },
                ),
                const SizedBox(height: 16),

                // Speech Speed Rate Slider
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Tốc độ đọc:',
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${(tts.speechRate * 2.0).toStringAsFixed(2)}x',
                      style: TextStyle(fontWeight: FontWeight.bold, color: colorScheme.primary),
                    ),
                  ],
                ),
                Slider(
                  value: tts.speechRate,
                  min: 0.25,
                  max: 1.0,
                  divisions: 15,
                  label: '${(tts.speechRate * 2.0).toStringAsFixed(2)}x',
                  onChanged: (val) => tts.setSpeechRate(val),
                ),

                // Speech Pitch Slider
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Cao độ (Pitch):',
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      tts.pitch.toStringAsFixed(2),
                      style: TextStyle(fontWeight: FontWeight.bold, color: colorScheme.primary),
                    ),
                  ],
                ),
                Slider(
                  value: tts.pitch,
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  label: tts.pitch.toStringAsFixed(2),
                  onChanged: (val) => tts.setPitch(val),
                ),

                const SizedBox(height: 16),

                // Preview Button (🔊 Nghe thử)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: colorScheme.primaryContainer,
                      foregroundColor: colorScheme.onPrimaryContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.volume_up_rounded),
                    label: const Text(
                      '🔊 Nghe thử (tối đa 200 ký tự)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () {
                      final sample = textContent.isNotEmpty
                          ? textContent.substring(0, min(200, textContent.length))
                          : 'Vào thời xa xưa, thế giới này vốn chìm trong hư vô và tĩnh lặng.';
                      tts.speakPreview(sample);
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }
}
