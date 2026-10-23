import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../features/translator_bot/ui/ellie_chat_screen.dart';
import '../models/story.dart';
import '../services/google_drive_service.dart';

class PdfReaderScreen extends StatefulWidget {
  final Story story;

  const PdfReaderScreen({super.key, required this.story});

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  File? _pdfFile;
  bool _isLoading = false;
  String? _error;
  double? _progress;
  int _receivedBytes = 0;
  int? _totalBytes;

  @override
  void initState() {
    super.initState();
    _preparePdf();
  }

  Future<void> _preparePdf() async {
    if (!widget.story.isFromDrive || widget.story.localPath.isNotEmpty) {
      _pdfFile = File(widget.story.localPath);
      return;
    }

    setState(() => _isLoading = true);
    try {
      final directory = await getApplicationDocumentsDirectory();
      final cacheDirectory = Directory('${directory.path}/drive_read_cache');
      await cacheDirectory.create(recursive: true);
      final safeId = widget.story.driveFileId.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '_',
      );
      final cachedFile = File('${cacheDirectory.path}/$safeId.pdf');
      if (await cachedFile.exists() && await cachedFile.length() > 0) {
        _pdfFile = cachedFile;
      } else {
        _pdfFile = await GoogleDriveService.downloadFileToFile(
          widget.story.driveFileId,
          cachedFile,
          onProgress: (receivedBytes, totalBytes) {
            if (!mounted) return;
            setState(() {
              _receivedBytes = receivedBytes;
              _totalBytes = totalBytes;
              _progress = totalBytes != null && totalBytes > 0
                  ? receivedBytes / totalBytes
                  : null;
            });
          },
        );
      }
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _isLoading = false);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }

  Widget _buildLoadingState() {
    final label = _totalBytes == null
        ? _formatBytes(_receivedBytes)
        : '${_formatBytes(_receivedBytes)} / ${_formatBytes(_totalBytes!)}';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 220,
              child: LinearProgressIndicator(value: _progress),
            ),
            const SizedBox(height: 16),
            const Text('Đang chuẩn bị PDF từ Drive...'),
            if (_receivedBytes > 0) ...[
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
            const SizedBox(height: 12),
            const Text(
              'Không thể mở PDF',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openTranslatorWithEllie() async {
    final file = _pdfFile;
    if (file == null || !await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tệp PDF chưa sẵn sàng để trích xuất văn bản.')),
        );
      }
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Text('Đang trích xuất văn bản PDF...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final bytes = await file.readAsBytes();
      final document = PdfDocument(inputBytes: bytes);
      final extractor = PdfTextExtractor(document);
      final extractedText = extractor.extractText();
      document.dispose();

      if (mounted) Navigator.of(context, rootNavigator: true).pop();

      if (extractedText.trim().isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Tệp PDF này không có lớp text số hóa (dạng scan ảnh) nên không thể trích xuất văn bản trực tiếp.',
              ),
            ),
          );
        }
        return;
      }

      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => EllieChatScreen(
              initialText: extractedText,
              initialTitle: widget.story.title,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi trích xuất PDF: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _pdfFile;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.story.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.translate_rounded),
            tooltip: 'Dịch truyện cùng Ellie Bot',
            onPressed: _openTranslatorWithEllie,
          ),
        ],
      ),
      body: _isLoading
          ? _buildLoadingState()
          : _error != null
          ? _buildErrorState()
          : file == null
          ? const Center(child: CircularProgressIndicator())
          : SfPdfViewer.file(
              file,
              canShowScrollHead: false,
              canShowScrollStatus: false,
            ),
    );
  }
}
