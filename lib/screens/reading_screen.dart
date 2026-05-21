import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/story.dart';
import '../theme/reading_settings_provider.dart';

class ReadingScreen extends StatefulWidget {
  final Story story;

  const ReadingScreen({super.key, required this.story});

  @override
  State<ReadingScreen> createState() => _ReadingScreenState();
}

class _ReadingScreenState extends State<ReadingScreen> {
  bool _showEnglish = false;
  bool _showToolbar = false;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ReadingSettingsProvider>();

    return Scaffold(
      backgroundColor: settings.bgColor,
      body: GestureDetector(
        onTapUp: (details) {
          final width = MediaQuery.of(context).size.width;
          final dx = details.globalPosition.dx;
          if (dx < width * 0.25) {
            // Placeholder: Mở danh sách chương hoặc cuộn lên (nếu muốn)
          } else if (dx > width * 0.75) {
            // Placeholder: Chuyển chương tiếp theo hoặc cuộn xuống
          } else {
            setState(() {
              _showToolbar = !_showToolbar;
            });
          }
        },
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 40.0),
              child: Text(
                _showEnglish && widget.story.contentEng.isNotEmpty
                    ? widget.story.contentEng
                    : widget.story.content,
                style: settings.bodyTextStyle,
              ),
            ),

            // Top Toolbar
            if (_showToolbar)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppBar(
                  backgroundColor: Colors.black87,
                  foregroundColor: Colors.white,
                  title: Text(widget.story.title, style: const TextStyle(fontSize: 16)),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.language),
                      onPressed: () {
                        if (widget.story.contentEng.isNotEmpty) {
                          setState(() {
                            _showEnglish = !_showEnglish;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ),

            // Bottom Toolbar
            if (_showToolbar)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black87,
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Font size control
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Cỡ chữ', style: TextStyle(color: Colors.white)),
                          IconButton(
                            icon: const Icon(Icons.remove, color: Colors.white),
                            onPressed: () => settings.setFontSize(settings.fontSize - 1),
                          ),
                          Text('${settings.fontSize.toInt()}', style: const TextStyle(color: Colors.white)),
                          IconButton(
                            icon: const Icon(Icons.add, color: Colors.white),
                            onPressed: () => settings.setFontSize(settings.fontSize + 1),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Chapter nav (Fake for TXT)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(onPressed: () {}, child: const Text('Trước', style: TextStyle(color: Colors.white))),
                          const Text('Cuộn để đọc', style: TextStyle(color: Colors.white)),
                          TextButton(onPressed: () {}, child: const Text('Tiếp', style: TextStyle(color: Colors.white))),
                        ],
                      )
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
