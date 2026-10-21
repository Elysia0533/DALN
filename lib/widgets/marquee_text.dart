import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';

class MarqueeText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final double height;
  final double blankSpace;
  final double velocity;
  final Duration pauseAfterRound;
  final Duration startPadding;

  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.height = 24.0,
    this.blankSpace = 30.0,
    this.velocity = 30.0,
    this.pauseAfterRound = const Duration(seconds: 1),
    this.startPadding = const Duration(seconds: 2),
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate the width of the text
        final textSpan = TextSpan(text: text, style: style);
        final textPainter = TextPainter(
          text: textSpan,
          maxLines: 1,
          textDirection: TextDirection.ltr,
        );
        textPainter.layout(minWidth: 0, maxWidth: double.infinity);

        // If the text fits within the available width, just show a normal Text
        if (textPainter.width <= constraints.maxWidth) {
          return Text(
            text,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        // Otherwise, show the Marquee
        return SizedBox(
          height: height,
          child: Marquee(
            text: text,
            style: style,
            scrollAxis: Axis.horizontal,
            crossAxisAlignment: CrossAxisAlignment.center,
            blankSpace: blankSpace,
            velocity: velocity,
            pauseAfterRound: pauseAfterRound,
            startPadding: 0,
            accelerationDuration: const Duration(milliseconds: 500),
            accelerationCurve: Curves.easeOut,
            decelerationDuration: const Duration(milliseconds: 500),
            decelerationCurve: Curves.easeOut,
          ),
        );
      },
    );
  }
}
