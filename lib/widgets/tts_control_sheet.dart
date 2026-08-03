import 'package:flutter/material.dart';
import '../services/tts_service.dart';
import '../services/ambient_audio_service.dart';

class TtsControlSheet extends StatelessWidget {
  final String textContent;
  final VoidCallback? onNextChapter;

  const TtsControlSheet({
    super.key,
    required this.textContent,
    this.onNextChapter,
  });

  static void show(BuildContext context, {required String textContent, VoidCallback? onNextChapter}) {
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
    final ambient = AmbientAudioService.instance;
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: Listenable.merge([tts, ambient]),
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(50),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          padding: const EdgeInsets.all(20),
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
                    color: Colors.grey.withAlpha(100),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Title & State Indicator
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Icon(Icons.record_voice_over, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Đọc truyện tự động (TTS)',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (tts.timerMinutesRemaining > 0)
                    Chip(
                      avatar: const Icon(Icons.timer, size: 16),
                      label: Text('${tts.timerMinutesRemaining}m'),
                      backgroundColor: theme.colorScheme.primaryContainer,
                    ),
                  if (tts.stopAtEndOfChapter)
                    Chip(
                      avatar: const Icon(Icons.check_circle_outline, size: 16),
                      label: const Text('Hết chương'),
                      backgroundColor: theme.colorScheme.secondaryContainer,
                    ),
                ],
              ),
              const SizedBox(height: 20),

              // Media Control Buttons Bar
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton.filledTonal(
                    onPressed: () {
                      tts.setSpeechRate((tts.speechRate - 0.1).clamp(0.2, 1.0));
                    },
                    icon: const Icon(Icons.remove),
                    tooltip: 'Giảm tốc độ',
                  ),
                  FloatingActionButton.large(
                    heroTag: 'tts_main_play_btn',
                    onPressed: () {
                      if (tts.isPlaying) {
                        tts.pause();
                      } else if (tts.state == TtsState.paused) {
                        tts.resume();
                      } else {
                        tts.speak(textContent, onChapterComplete: onNextChapter);
                      }
                    },
                    child: Icon(
                      tts.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 40,
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: () {
                      tts.setSpeechRate((tts.speechRate + 0.1).clamp(0.2, 1.0));
                    },
                    icon: const Icon(Icons.add),
                    tooltip: 'Tăng tốc độ',
                  ),
                  IconButton.filledTonal(
                    onPressed: () => tts.stop(),
                    icon: const Icon(Icons.stop_rounded),
                    color: Colors.redAccent,
                    tooltip: 'Dừng đọc',
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Speech Speed Slider
              Text('Tốc độ đọc: ${(tts.speechRate * 2).toStringAsFixed(1)}x'),
              Slider(
                value: tts.speechRate,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                onChanged: (val) => tts.setSpeechRate(val),
              ),

              const Divider(height: 24),

              // Sleep Timer Selection
              Text(
                'Hẹn giờ tắt (Sleep Timer):',
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('15 phút'),
                    selected: tts.timerMinutesRemaining == 15,
                    onSelected: (val) => tts.startSleepTimer(15),
                  ),
                  ChoiceChip(
                    label: const Text('30 phút'),
                    selected: tts.timerMinutesRemaining == 30,
                    onSelected: (val) => tts.startSleepTimer(30),
                  ),
                  ChoiceChip(
                    label: const Text('60 phút'),
                    selected: tts.timerMinutesRemaining == 60,
                    onSelected: (val) => tts.startSleepTimer(60),
                  ),
                  ChoiceChip(
                    label: const Text('Hết chương'),
                    selected: tts.stopAtEndOfChapter,
                    onSelected: (val) => tts.setStopAtEndOfChapter(val),
                  ),
                ],
              ),

              const Divider(height: 24),

              // Ambient Sound Selection (Nhạc nền đọc truyện)
              Row(
                children: [
                  Icon(Icons.music_note, color: theme.colorScheme.secondary),
                  const SizedBox(width: 8),
                  Text(
                    'Nhạc nền thư giãn:',
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: AmbientSound.values.map((sound) {
                  final isSelected = ambient.currentSound == sound;
                  return ChoiceChip(
                    label: Text(ambient.getLabel(sound)),
                    selected: isSelected,
                    onSelected: (_) => ambient.selectSound(sound),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }
}
