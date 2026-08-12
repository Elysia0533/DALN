import 'package:flutter/material.dart';

import '../services/tts_service.dart';

class TtsPlayerContainer extends StatelessWidget {
  final Color textColor;
  final VoidCallback? onPreviousChapter;
  final VoidCallback? onNextChapter;
  final VoidCallback? onOpenSettings;

  const TtsPlayerContainer({
    super.key,
    required this.textColor,
    this.onPreviousChapter,
    this.onNextChapter,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TtsService.instance,
      builder: (context, _) {
        final tts = TtsService.instance;
        if (tts.isStopped) return const SizedBox.shrink();

        final colorScheme = Theme.of(context).colorScheme;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final textScale = MediaQuery.textScalerOf(context).scale(1);
              final compact = constraints.maxWidth < 420 || textScale >= 1.3;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: compact
                        ? MainAxisAlignment.spaceBetween
                        : MainAxisAlignment.spaceEvenly,
                    children: [
                      _TtsControlButton(
                        key: const ValueKey('tts_previous_chapter'),
                        icon: Icons.skip_previous_rounded,
                        label: 'Chap trước',
                        tooltip: 'Chương trước',
                        color: colorScheme.primary,
                        textColor: colorScheme.onSurface,
                        showLabel: !compact,
                        onTap:
                            onPreviousChapter ?? () => tts.previousParagraph(),
                      ),
                      IconButton.filledTonal(
                        key: const ValueKey('tts_previous_paragraph'),
                        iconSize: 20,
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                        icon: const Icon(Icons.navigate_before_rounded),
                        tooltip: 'Đoạn trước',
                        onPressed: () => tts.previousParagraph(),
                      ),
                      IconButton.filled(
                        key: const ValueKey('tts_play_pause'),
                        iconSize: 26,
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        icon: Icon(
                          tts.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        tooltip: tts.isPlaying ? 'Tạm dừng' : 'Phát tiếp',
                        onPressed: () {
                          if (tts.isPlaying) {
                            tts.pause();
                          } else {
                            tts.resume();
                          }
                        },
                      ),
                      IconButton.filledTonal(
                        key: const ValueKey('tts_next_paragraph'),
                        iconSize: 20,
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                        icon: const Icon(Icons.navigate_next_rounded),
                        tooltip: 'Đoạn kế',
                        onPressed: () => tts.nextParagraph(),
                      ),
                      _TtsControlButton(
                        key: const ValueKey('tts_next_chapter'),
                        icon: Icons.skip_next_rounded,
                        label: 'Chap kế',
                        tooltip: 'Chương kế',
                        color: colorScheme.primary,
                        textColor: colorScheme.onSurface,
                        showLabel: !compact,
                        iconAfterLabel: true,
                        onTap: onNextChapter ?? () => tts.nextParagraph(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Divider(
                    height: 1,
                    color: colorScheme.outlineVariant.withValues(alpha: 0.25),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: compact
                        ? MainAxisAlignment.spaceEvenly
                        : MainAxisAlignment.spaceAround,
                    children: [
                      _TtsControlButton(
                        key: const ValueKey('tts_sleep_timer'),
                        icon: Icons.timer_outlined,
                        label: tts.timerMinutesRemaining > 0
                            ? '${tts.timerMinutesRemaining}m'
                            : 'Hẹn giờ',
                        tooltip: 'Hẹn giờ tắt TTS',
                        color: tts.timerMinutesRemaining > 0
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        textColor: tts.timerMinutesRemaining > 0
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        showLabel: !compact,
                        dense: true,
                        onTap: () => _showSleepTimerDialog(context, tts),
                      ),
                      _TtsControlButton(
                        key: const ValueKey('tts_settings'),
                        icon: Icons.settings_outlined,
                        label: 'Cài đặt',
                        tooltip: 'Cài đặt TTS',
                        color: colorScheme.onSurfaceVariant,
                        textColor: colorScheme.onSurfaceVariant,
                        showLabel: !compact,
                        dense: true,
                        onTap: onOpenSettings,
                      ),
                      _TtsControlButton(
                        key: const ValueKey('tts_close'),
                        icon: Icons.close_rounded,
                        label: 'Tắt',
                        tooltip: 'Tắt TTS',
                        color: Colors.redAccent,
                        textColor: Colors.redAccent,
                        showLabel: !compact,
                        dense: true,
                        onTap: () => tts.stop(),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _showSleepTimerDialog(BuildContext context, TtsService tts) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hẹn giờ tắt TTS'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Không hẹn giờ'),
              trailing: tts.timerMinutesRemaining == 0
                  ? const Icon(Icons.check, color: Colors.green)
                  : null,
              onTap: () {
                tts.startSleepTimer(0);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('15 phút'),
              trailing: tts.timerMinutesRemaining == 15
                  ? const Icon(Icons.check, color: Colors.green)
                  : null,
              onTap: () {
                tts.startSleepTimer(15);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('30 phút'),
              trailing: tts.timerMinutesRemaining == 30
                  ? const Icon(Icons.check, color: Colors.green)
                  : null,
              onTap: () {
                tts.startSleepTimer(30);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('60 phút'),
              trailing: tts.timerMinutesRemaining == 60
                  ? const Icon(Icons.check, color: Colors.green)
                  : null,
              onTap: () {
                tts.startSleepTimer(60);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TtsControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final Color color;
  final Color textColor;
  final bool showLabel;
  final bool iconAfterLabel;
  final bool dense;
  final VoidCallback? onTap;

  const _TtsControlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.color,
    required this.textColor,
    required this.showLabel,
    this.iconAfterLabel = false,
    this.dense = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final iconWidget = Icon(icon, size: dense ? 16 : 18, color: color);
    final labelWidget = Flexible(
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: dense ? FontWeight.w500 : FontWeight.w600,
          color: textColor,
        ),
      ),
    );
    final children = iconAfterLabel
        ? <Widget>[labelWidget, const SizedBox(width: 4), iconWidget]
        : <Widget>[iconWidget, const SizedBox(width: 4), labelWidget];

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(dense ? 10 : 12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: showLabel ? (dense ? 10 : 8) : 0,
              vertical: 6,
            ),
            child: Center(
              child: showLabel
                  ? Row(mainAxisSize: MainAxisSize.min, children: children)
                  : iconWidget,
            ),
          ),
        ),
      ),
    );
  }
}
