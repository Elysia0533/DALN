import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../models/community_message.dart';
import '../services/api_service.dart';
import '../theme/user_provider.dart';
import '../widgets/app_state_widgets.dart';

class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<CommunityMessage> _messages = [];
  bool _isLoading = false;
  bool _isSending = false;
  String? _error;
  String? _loadedToken;

  static const List<String> _quickEmojis = [
    '😊',
    '😂',
    '😍',
    '👍',
    '🔥',
    '😭',
    '✨',
    '❤️',
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final user = context.watch<UserProvider>();
    final loadToken = user.isLoggedIn ? user.token : 'guest';
    if (_loadedToken != loadToken) {
      _loadedToken = loadToken;
      _loadMessages();
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final messages = await ApiService.fetchCommunityMessages();
      if (!mounted) return;
      setState(() => _messages = messages);
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _formatError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    try {
      final message = await ApiService.sendCommunityMessage(text);
      if (!mounted) return;
      _messageController.clear();
      setState(() {
        _messages = [..._messages, message];
        _error = null;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      final lower = e.toString().toLowerCase();
      if (lower.contains('permission-denied') ||
          lower.contains('quyền') ||
          lower.contains('quyen')) {
        await context.read<UserProvider>().refreshAdminClaim();
        if (!mounted) return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_formatError(e))));
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _deleteMessage(CommunityMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xóa tin nhắn'),
        content: const Text('Tin nhắn này sẽ bị xóa khỏi cộng đồng.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ApiService.deleteCommunityMessage(message.id);
      if (!mounted) return;
      setState(() {
        _messages = _messages
            .where((item) => item.id != message.id)
            .toList(growable: false);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Đã xóa tin nhắn.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_formatError(e))));
    }
  }

  void _insertEmoji(String emoji) {
    final value = _messageController.value;
    final start = value.selection.start < 0
        ? value.text.length
        : value.selection.start;
    final end = value.selection.end < 0
        ? value.text.length
        : value.selection.end;
    final updated = value.text.replaceRange(start, end, emoji);
    _messageController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  ImageProvider? _avatarImageProvider(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return NetworkImage(trimmed);
    }
    final file = File(trimmed);
    if (file.existsSync()) return FileImage(file);
    return null;
  }

  Color _messageAvatarColor(
    CommunityMessage message,
    UserProvider user,
    bool isMine,
  ) {
    if (isMine) return user.avatarColor;
    final colors = UserProvider.avatarColors
        .map((item) => item['value'] as int)
        .toList(growable: false);
    final key = message.userId.isNotEmpty
        ? message.userId
        : message.displayName;
    final hash = key.codeUnits.fold<int>(
      0,
      (value, unit) => 0x1fffffff & (value * 31 + unit),
    );
    return Color(colors[hash % colors.length]);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  String _formatError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.contains('FIREBASE_') ||
        message.toLowerCase().contains('đồng bộ') ||
        message.toLowerCase().contains('dong bo')) {
      return 'Không tải được cộng đồng đám mây. Bạn vẫn có thể dùng tài khoản và tin nhắn local trên thiết bị.';
    }
    return message;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final appBarColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    final userProvider = context.watch<UserProvider>();

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: appBarColor,
        elevation: 0,
        title: Text(
          'Cộng đồng',
          style: TextStyle(fontWeight: FontWeight.bold, color: textColor),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: textColor),
            onPressed: _loadMessages,
            tooltip: 'Làm mới',
          ),
        ],
      ),
      body: _buildChat(context, isDark, textColor, userProvider),
    );
  }

  Widget _buildGuestInputPrompt(bool isDark) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1C1C1E) : Colors.grey.shade50,
          border: Border(
            top: BorderSide(color: isDark ? Colors.white10 : Colors.black12),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.lock_outline_rounded,
              color: colorScheme.onSurfaceVariant,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Đăng nhập ở tab Cá nhân để gửi tin nhắn.',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChat(
    BuildContext context,
    bool isDark,
    Color textColor,
    UserProvider user,
  ) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1C1C1E) : Colors.grey.shade50,
            border: Border(
              bottom: BorderSide(
                color: isDark ? Colors.white10 : Colors.black12,
              ),
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: user.isLoggedIn
                    ? user.avatarColor
                    : Theme.of(context).colorScheme.primary,
                backgroundImage: user.isLoggedIn
                    ? _avatarImageProvider(user.avatarUrl)
                    : null,
                child:
                    !user.isLoggedIn ||
                        _avatarImageProvider(user.avatarUrl) == null
                    ? Text(
                        user.isLoggedIn ? user.initials : 'K',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.isLoggedIn ? user.name : 'Khách',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      user.isLoggedIn
                          ? 'Sẵn sàng trò chuyện'
                          : 'Bạn có thể đọc cộng đồng',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isDark
                            ? Colors.grey.shade500
                            : Colors.grey.shade600,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _isLoading
              ? const AppLoadingState(message: 'Đang tải tin nhắn...')
              : _error != null
              ? _buildErrorState()
              : _messages.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[index];
                    final previous = index > 0 ? _messages[index - 1] : null;
                    final isMine = message.userId == user.id;
                    final avatarUrl = isMine && message.avatarUrl.trim().isEmpty
                        ? user.avatarUrl
                        : message.avatarUrl;
                    return Column(
                      children: [
                        if (_shouldShowTimeline(previous, message))
                          _TimelineSeparator(
                            label: _formatTimelineDate(message.createdAt),
                            isDark: isDark,
                          ),
                        _MessageBubble(
                          message: message,
                          isMine: isMine,
                          isDark: isDark,
                          mineColor: user.avatarColor,
                          avatarUrl: avatarUrl,
                          avatarColor: _messageAvatarColor(
                            message,
                            user,
                            isMine,
                          ),
                          canModerate: user.isAdmin,
                          onDelete: user.isAdmin
                              ? () => _deleteMessage(message)
                              : null,
                        ),
                      ],
                    );
                  },
                ),
        ),
        if (user.isLoggedIn)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 36,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _quickEmojis.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (context, index) {
                        final emoji = _quickEmojis[index];
                        return ActionChip(
                          label: Text(emoji),
                          onPressed: () => _insertEmoji(emoji),
                          visualDensity: VisualDensity.compact,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendMessage(),
                          decoration: InputDecoration(
                            hintText: 'Nhập tin nhắn...',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: _isSending ? null : _sendMessage,
                        icon: _isSending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send_rounded),
                        tooltip: 'Gửi',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          )
        else
          _buildGuestInputPrompt(isDark),
      ],
    );
  }

  Widget _buildErrorState() {
    return AppErrorState(
      icon: Icons.cloud_off_rounded,
      title: 'Không tải được cộng đồng',
      message: _error ?? 'Không tải được tin nhắn. Vui lòng thử lại.',
      actionLabel: 'Thử lại',
      onAction: _loadMessages,
    );
  }

  Widget _buildEmptyState() {
    return const AppEmptyState(
      icon: Icons.chat_bubble_outline_rounded,
      title: 'Chưa có tin nhắn',
      message:
          'Hãy bắt đầu cuộc trò chuyện đầu tiên trong cộng đồng đọc truyện.',
    );
  }

  bool _shouldShowTimeline(
    CommunityMessage? previous,
    CommunityMessage current,
  ) {
    final currentDate = _parseMessageTime(current.createdAt);
    if (currentDate == null) return previous == null;
    final previousDate = previous == null
        ? null
        : _parseMessageTime(previous.createdAt);
    if (previousDate == null) return true;
    return currentDate.year != previousDate.year ||
        currentDate.month != previousDate.month ||
        currentDate.day != previousDate.day;
  }

  DateTime? _parseMessageTime(String value) {
    if (value.trim().isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  String _formatTimelineDate(String value) {
    final date = _parseMessageTime(value);
    if (date == null) return 'Hôm nay';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = today.difference(target).inDays;
    if (diff == 0) return 'Hôm nay';
    if (diff == 1) return 'Hôm qua';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}

class _MessageBubble extends StatelessWidget {
  final CommunityMessage message;
  final bool isMine;
  final bool isDark;
  final Color mineColor;
  final String avatarUrl;
  final Color avatarColor;
  final bool canModerate;
  final VoidCallback? onDelete;

  const _MessageBubble({
    required this.message,
    required this.isMine,
    required this.isDark,
    required this.mineColor,
    required this.avatarUrl,
    required this.avatarColor,
    required this.canModerate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final bubbleColor = isMine
        ? mineColor
        : (isDark ? const Color(0xFF242426) : Colors.grey.shade100);
    final textColor = isMine
        ? Colors.white
        : (isDark ? Colors.white : Colors.black87);
    final timeLabel = _formatMessageTime(message.createdAt);

    final avatar = _MessageAvatar(
      imagePath: avatarUrl,
      displayName: message.displayName,
      color: avatarColor,
    );

    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 310),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine || canModerate)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isMine)
                    Flexible(
                      child: Text(
                        message.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isDark
                              ? Colors.grey.shade400
                              : Colors.grey.shade600,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  if (canModerate) ...[
                    if (!isMine) const SizedBox(width: 6),
                    InkWell(
                      onTap: onDelete,
                      borderRadius: BorderRadius.circular(999),
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Icon(
                          Icons.delete_outline_rounded,
                          size: 15,
                          color: isMine
                              ? Colors.white.withValues(alpha: 0.82)
                              : Colors.red.withValues(alpha: 0.82),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (message.attachmentPath.trim().isNotEmpty ||
              message.attachmentType.trim().isNotEmpty) ...[
            _MessageAttachment(
              isMine: isMine,
              attachmentOnly: message.text.trim().isEmpty,
            ),
            if (message.text.isNotEmpty) const SizedBox(height: 6),
          ],
          if (message.text.isNotEmpty)
            Text(
              message.text,
              style: TextStyle(color: textColor, fontSize: 14, height: 1.35),
            ),
          if (timeLabel.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              timeLabel,
              style: TextStyle(
                color: textColor.withValues(alpha: 0.68),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) ...[avatar, const SizedBox(width: 8)],
          Flexible(
            child: Align(
              alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
              child: bubble,
            ),
          ),
          if (isMine) ...[const SizedBox(width: 8), avatar],
        ],
      ),
    );
  }

  String _formatMessageTime(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return '';
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class _MessageAvatar extends StatelessWidget {
  final String imagePath;
  final String displayName;
  final Color color;

  const _MessageAvatar({
    required this.imagePath,
    required this.displayName,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final image = _avatarImageProvider(imagePath);
    return CircleAvatar(
      radius: 16,
      backgroundColor: color,
      backgroundImage: image,
      child: image == null
          ? Text(
              _initials(displayName),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            )
          : null,
    );
  }

  ImageProvider? _avatarImageProvider(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return NetworkImage(trimmed);
    }
    final file = File(trimmed);
    if (file.existsSync()) return FileImage(file);
    return null;
  }

  String _initials(String value) {
    final parts = value
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return '${parts.first.characters.first}${parts.last.characters.first}'
        .toUpperCase();
  }
}

class _TimelineSeparator extends StatelessWidget {
  final String label;
  final bool isDark;

  const _TimelineSeparator({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF242426) : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageAttachment extends StatelessWidget {
  final bool isMine;
  final bool attachmentOnly;

  const _MessageAttachment({
    required this.isMine,
    required this.attachmentOnly,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = isMine ? Colors.white : colorScheme.onSurfaceVariant;
    final background = Colors.black.withValues(alpha: isMine ? 0.18 : 0.08);

    return Container(
      width: 220,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.hide_image_outlined, color: foreground, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              attachmentOnly
                  ? 'Tệp đính kèm cũ không còn được hỗ trợ.'
                  : 'Tệp đính kèm cũ đã bị ẩn.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
