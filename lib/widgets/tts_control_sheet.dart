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
    final colorScheme = theme.colorScheme;

    return AnimatedBuilder(
      animation: Listenable.merge([tts, ambient]),
      builder: (context, child) {
        final totalChunks = tts.totalChunks;
        final currentChunk = tts.currentChunkIndex + 1;
        final progressPct = totalChunks > 0 ? (currentChunk / totalChunks * 100).toInt() : 0;

        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
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
                        Icon(Icons.record_voice_over, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Đọc truyện bằng giọng nói (TTS)',
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
                      backgroundColor: colorScheme.primaryContainer,
                    ),
                  if (tts.stopAtEndOfChapter)
                    Chip(
                      avatar: const Icon(Icons.check_circle_outline, size: 16),
                      label: const Text('Hết chương'),
                      backgroundColor: colorScheme.secondaryContainer,
                    ),
                ],
              ),

              if (totalChunks > 0) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Tiến trình đọc: Đoạn $currentChunk/$totalChunks ($progressPct%)',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                    ),
                    if (onNextChapter != null)
                      Text(
                        'Tự động qua chương mới',
                        style: TextStyle(fontSize: 11, color: colorScheme.primary, fontStyle: FontStyle.italic),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: totalChunks > 0 ? (currentChunk / totalChunks) : 0,
                    minHeight: 6,
                    color: colorScheme.primary,
                    backgroundColor: colorScheme.primaryContainer.withAlpha(100),
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // Media Control Buttons Bar (Prev Chunk, Play/Pause, Next Chunk, Stop)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton.filledTonal(
                    onPressed: tts.currentChunkIndex > 0 ? () => tts.previousChunk() : null,
                    icon: const Icon(Icons.skip_previous_rounded),
                    tooltip: 'Đoạn trước',
                  ),
                  FloatingActionButton.large(
                    heroTag: 'tts_main_play_btn',
                    onPressed: () {
                      if (tts.isPlaying) {
                        tts.pause();
                      } else if (tts.isPaused) {
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
                    onPressed: tts.currentChunkIndex < totalChunks - 1 ? () => tts.nextChunk() : null,
                    icon: const Icon(Icons.skip_next_rounded),
                    tooltip: 'Đoạn sau',
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
                  Icon(Icons.music_note, color: colorScheme.secondary),
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
