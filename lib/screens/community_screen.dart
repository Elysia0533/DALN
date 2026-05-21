import 'package:flutter/material.dart';

class CommunityScreen extends StatelessWidget {
  const CommunityScreen({super.key});

  // Giả lập trạng thái chưa đăng nhập
  final bool isLoggedIn = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final appBarColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: appBarColor,
        elevation: 0,
        title: Text('Cộng đồng', style: TextStyle(fontWeight: FontWeight.bold, color: textColor)),
        actions: [
          IconButton(
            icon: Icon(Icons.more_vert, color: textColor),
            onPressed: () {},
          ),
        ],
      ),
      body: isLoggedIn ? _buildChatInterface(isDark, textColor) : _buildLoginPrompt(isDark, textColor),
    );
  }

  Widget _buildLoginPrompt(bool isDark, Color textColor) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.forum_outlined, size: 80, color: isDark ? Colors.grey.shade600 : Colors.grey.shade400),
            const SizedBox(height: 24),
            Text(
              'Chưa đăng nhập',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textColor),
            ),
            const SizedBox(height: 12),
            Text(
              'Vui lòng đăng nhập để xem tin nhắn và tham gia thảo luận cùng cộng đồng vBook.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: isDark ? Colors.grey.shade400 : Colors.grey.shade600, height: 1.5),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () {
                  // TODO: Chuyển hướng đến màn hình đăng nhập
                },
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                ),
                child: const Text('Đăng nhập ngay', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatInterface(bool isDark, Color textColor) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Text('Khu vực chat (Chỉ hiện khi đã đăng nhập)', style: TextStyle(color: textColor)),
          ),
        ),
      ],
    );
  }
}
