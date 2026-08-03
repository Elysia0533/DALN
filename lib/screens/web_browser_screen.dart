import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Màn hình trình duyệt web tích hợp.
/// Người dùng có thể đăng nhập tài khoản Hako (hoặc bất kỳ trang nào)
/// và cookies/session sẽ được lưu trong WebView để plugin sử dụng lại.
class WebBrowserScreen extends StatefulWidget {
  final String initialUrl;
  final String title;

  const WebBrowserScreen({
    super.key,
    required this.initialUrl,
    this.title = 'Trình duyệt',
  });

  @override
  State<WebBrowserScreen> createState() => _WebBrowserScreenState();
}

class _WebBrowserScreenState extends State<WebBrowserScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  int _loadingProgress = 0;
  String _currentUrl = '';
  String _pageTitle = '';
  bool _canGoBack = false;
  bool _canGoForward = false;
  final TextEditingController _urlController = TextEditingController();
  bool _isEditingUrl = false;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl;
    _urlController.text = widget.initialUrl;

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _isLoading = true;
              _currentUrl = url;
              if (!_isEditingUrl) _urlController.text = url;
            });
            _refreshNavButtons();
          },
          onProgress: (progress) {
            setState(() => _loadingProgress = progress);
          },
          onPageFinished: (url) async {
            final title = await _controller.getTitle();
            setState(() {
              _isLoading = false;
              _currentUrl = url;
              _pageTitle = title ?? '';
              if (!_isEditingUrl) _urlController.text = url;
            });
            _refreshNavButtons();
          },
          onWebResourceError: (error) {
            setState(() => _isLoading = false);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  Future<void> _refreshNavButtons() async {
    final back = await _controller.canGoBack();
    final forward = await _controller.canGoForward();
    if (mounted) {
      setState(() {
        _canGoBack = back;
        _canGoForward = forward;
      });
    }
  }

  void _navigate(String url) {
    String target = url.trim();
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      // Nếu nhập trực tiếp domain, thêm https://
      if (target.contains('.') && !target.contains(' ')) {
        target = 'https://$target';
      } else {
        // Tìm kiếm Google
        target =
            'https://www.google.com/search?q=${Uri.encodeComponent(target)}';
      }
    }
    _controller.loadRequest(Uri.parse(target));
    setState(() {
      _isEditingUrl = false;
      _urlController.text = target;
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Đóng',
        ),
        title: _buildAddressBar(isDark, colorScheme),
        actions: [
          IconButton(
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _isLoading
                ? () => _controller.reload()
                : () => _controller.reload(),
            tooltip: _isLoading ? 'Dừng' : 'Tải lại',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: _handleMenuAction,
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'home',
                child: ListTile(
                  leading: Icon(Icons.home_outlined),
                  title: Text('Trang chủ web'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: 'login',
                child: ListTile(
                  leading: Icon(Icons.login),
                  title: Text('Đăng nhập'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: 'clear_cookies',
                child: ListTile(
                  leading: Icon(Icons.delete_outline, color: Colors.red),
                  title: Text(
                    'Xoá cookies / Đăng xuất',
                    style: TextStyle(color: Colors.red),
                  ),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _isLoading
              ? LinearProgressIndicator(
                  value: _loadingProgress / 100,
                  backgroundColor: Colors.transparent,
                  minHeight: 3,
                )
              : const SizedBox(height: 3),
        ),
      ),
      body: Column(
        children: [
          // Navigation bar
          _buildNavBar(colorScheme, isDark),
          // WebView
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }

  Widget _buildAddressBar(bool isDark, ColorScheme colorScheme) {
    return GestureDetector(
      onTap: () {
        setState(() => _isEditingUrl = true);
        _urlController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _urlController.text.length,
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isDark
              ? colorScheme.surfaceContainerHighest
              : colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
        ),
        child: _isEditingUrl
            ? TextField(
                controller: _urlController,
                autofocus: true,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
                style: const TextStyle(fontSize: 14),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                onSubmitted: _navigate,
                onTapOutside: (_) {
                  setState(() {
                    _isEditingUrl = false;
                    _urlController.text = _currentUrl;
                  });
                },
              )
            : SizedBox(
                height: 36,
                child: Row(
                  children: [
                    Icon(
                      _currentUrl.startsWith('https://')
                          ? Icons.lock_outline
                          : Icons.lock_open_outlined,
                      size: 14,
                      color: _currentUrl.startsWith('https://')
                          ? Colors.green
                          : Colors.orange,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _pageTitle.isNotEmpty ? _pageTitle : _currentUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildNavBar(ColorScheme colorScheme, bool isDark) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: isDark
            ? colorScheme.surfaceContainerLow
            : colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios, size: 18),
            onPressed: _canGoBack ? () => _controller.goBack() : null,
            tooltip: 'Quay lại',
            color: _canGoBack
                ? colorScheme.onSurface
                : colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward_ios, size: 18),
            onPressed: _canGoForward ? () => _controller.goForward() : null,
            tooltip: 'Tiến',
            color: _canGoForward
                ? colorScheme.onSurface
                : colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          IconButton(
            icon: const Icon(Icons.home_outlined, size: 20),
            onPressed: () =>
                _controller.loadRequest(Uri.parse(widget.initialUrl)),
            tooltip: 'Trang chủ',
          ),
          IconButton(
            icon: const Icon(Icons.login_outlined, size: 20),
            onPressed: () {
              final baseUrl = widget.initialUrl.endsWith('/') 
                  ? widget.initialUrl.substring(0, widget.initialUrl.length - 1) 
                  : widget.initialUrl;
              _controller.loadRequest(Uri.parse('$baseUrl/login'));
            },
            tooltip: 'Đăng nhập',
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined, size: 20),
            onPressed: () async {
              // Copy URL
              final messenger = ScaffoldMessenger.of(context);
              final url = await _controller.currentUrl();
              if (url != null) {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('URL: $url'),
                    behavior: SnackBarBehavior.floating,
                    action: SnackBarAction(
                      label: 'OK',
                      onPressed: () {},
                    ),
                  ),
                );
              }
            },
            tooltip: 'Thông tin trang',
          ),
        ],
      ),
    );
  }

  void _handleMenuAction(String action) {
    final baseUrl = widget.initialUrl.endsWith('/') 
        ? widget.initialUrl.substring(0, widget.initialUrl.length - 1) 
        : widget.initialUrl;
    switch (action) {
      case 'home':
        _navigate(baseUrl);
        break;
      case 'login':
        _navigate('$baseUrl/login');
        break;
      case 'clear_cookies':
        _showClearCookiesDialog();
        break;
    }
  }

  Future<void> _showClearCookiesDialog() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá cookies?'),
        content: const Text(
          'Thao tác này sẽ đăng xuất bạn khỏi tất cả tài khoản trong trình duyệt.\n\nBạn có chắc chắn không?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await WebViewCookieManager().clearCookies();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đã xoá cookies. Bạn đã đăng xuất.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        _controller.reload();
      }
    }
  }
}
