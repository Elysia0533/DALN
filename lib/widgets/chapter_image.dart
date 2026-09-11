import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/online_chapter_content.dart';
import '../services/chapter_image_service.dart';

class ChapterImage extends StatefulWidget {
  const ChapterImage({super.key, required this.block, required this.referer});

  final ChapterBlock block;
  final String referer;

  @override
  State<ChapterImage> createState() => _ChapterImageState();
}

class _ChapterImageState extends State<ChapterImage> {
  Future<Uint8List>? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ChapterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.value != widget.block.value ||
        oldWidget.block.isLocal != widget.block.isLocal ||
        oldWidget.referer != widget.referer) {
      _load();
    }
  }

  void _load() {
    _bytes = widget.block.isLocal
        ? null
        : ChapterImageService.load(widget.block.value, referer: widget.referer);
  }

  Widget _failure() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image_outlined),
        const Text('Không tải được ảnh', textAlign: TextAlign.center),
        IconButton(
          tooltip: 'Tải lại ảnh',
          onPressed: () => setState(_load),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.block.isLocal) {
      return Image.file(
        File(widget.block.value),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _failure(),
      );
    }
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _failure();
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 240,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return Image.memory(
          snapshot.data!,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _failure(),
        );
      },
    );
  }
}
