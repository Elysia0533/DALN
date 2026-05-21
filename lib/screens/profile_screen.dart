import 'package:flutter/material.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  // Giả lập trạng thái chưa đăng nhập
  final bool isLoggedIn = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final sectionBgColor = isDark ? const Color(0xFF1C1C1E) : Colors.grey.shade100;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
        elevation: 0,
        title: Text('Cá nhân', style: TextStyle(fontWeight: FontWeight.bold, color: textColor)),
        actions: [
          if (isLoggedIn)
            Padding(
              padding: const EdgeInsets.only(right: 16.0, top: 10, bottom: 10),
              child: ElevatedButton(
                onPressed: () {},
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
                  foregroundColor: textColor,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: const Text('Đăng xuất', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            )
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Profile Header
            if (isLoggedIn)
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 40,
                          backgroundColor: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
                          child: Icon(Icons.person, size: 50, color: isDark ? Colors.grey.shade400 : Colors.grey.shade500),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: isDark ? Colors.grey.shade800 : Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: bgColor, width: 2),
                            ),
                            child: const Icon(Icons.image, size: 12),
                          ),
                        )
                      ],
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('elesis', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textColor)),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                border: Border.all(color: Colors.blue.shade300),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('Free', style: TextStyle(color: Colors.blue.shade300, fontSize: 10, fontWeight: FontWeight.bold)),
                            )
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text('vglduc25@gmail.com', style: TextStyle(color: isDark ? Colors.grey.shade500 : Colors.grey.shade600)),
                      ],
                    )
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundColor: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
                      child: Icon(Icons.person, size: 50, color: isDark ? Colors.grey.shade500 : Colors.grey.shade400),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Khách', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textColor)),
                          const SizedBox(height: 8),
                          ElevatedButton(
                            onPressed: () {},
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).primaryColor,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                            ),
                            child: const Text('Đăng nhập / Đăng ký', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    )
                  ],
                ),
              ),

            // Ứng dụng Section
            _buildSectionHeader('Ứng dụng', sectionBgColor, textColor),
            _buildListTile(Icons.book_outlined, 'Lưu trữ', isDark),
            _buildListTile(Icons.bar_chart_rounded, 'Thống kê', isDark),
            _buildListTile(Icons.extension_outlined, 'Phần mở rộng', isDark),
            _buildListTile(Icons.sync_rounded, 'Đồng bộ & sao lưu', isDark),
            _buildListTile(Icons.settings_outlined, 'Cài đặt', isDark),

            // Kết nối Section
            _buildSectionHeader('Kết nối', sectionBgColor, textColor),
            _buildListTile(Icons.share_outlined, 'Mời bạn bè sử dụng', isDark),
            _buildListTile(Icons.facebook_outlined, 'Theo dõi Fanpage', isDark),
            _buildListTile(Icons.discord_outlined, 'Tham gia discord', isDark),

            const SizedBox(height: 32),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Phiên bản: 1.1.56', style: TextStyle(color: isDark ? Colors.grey.shade500 : Colors.grey.shade600)),
                  const SizedBox(width: 8),
                  Icon(Icons.refresh, size: 16, color: isDark ? Colors.grey.shade500 : Colors.grey.shade600),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, Color bgColor, Color textColor) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      color: bgColor,
      child: Text(
        title,
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textColor),
      ),
    );
  }

  Widget _buildListTile(IconData icon, String title, bool isDark) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: Icon(icon, color: isDark ? Colors.white70 : Colors.black87),
      title: Text(title, style: TextStyle(fontSize: 16, color: isDark ? Colors.white : Colors.black87)),
      onTap: () {},
    );
  }
}
