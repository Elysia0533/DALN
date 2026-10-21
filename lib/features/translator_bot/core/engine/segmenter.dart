import '../models/translation_models.dart';

class TextSegmenter {
  /// Tách văn bản thô thành danh sách các đoạn văn bản sạch có ID (p001, p002...)
  static List<TranslationSegment> segmentText(String rawText) {
    if (rawText.trim().isEmpty) return [];

    // Chuẩn hóa dòng mới
    final normalized = rawText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rawParagraphs = normalized.split(RegExp(r'\n\s*\n+'));

    final segments = <TranslationSegment>[];
    int counter = 1;

    for (var para in rawParagraphs) {
      para = para.trim();
      if (para.isEmpty) continue;

      // Nếu 1 đoạn quá dài (> 2000 ký tự), tách tiếp theo dấu ngắt câu để tránh quá tải
      if (para.length > 2000) {
        final subParas = _splitLargeParagraph(para);
        for (final sub in subParas) {
          final id = 'p${counter.toString().padLeft(3, '0')}';
          segments.add(TranslationSegment(id: id, sourceText: sub));
          counter++;
        }
      } else {
        final id = 'p${counter.toString().padLeft(3, '0')}';
        segments.add(TranslationSegment(id: id, sourceText: para));
        counter++;
      }
    }

    return segments;
  }

  static List<String> _splitLargeParagraph(String text) {
    final sentences = text.split(RegExp(r'(?<=[.!?。！？])\s+'));
    final result = <String>[];
    final current = StringBuffer();

    for (final s in sentences) {
      if (current.length + s.length > 1500 && current.isNotEmpty) {
        result.add(current.toString().trim());
        current.clear();
      }
      if (current.isNotEmpty) current.write(' ');
      current.write(s);
    }
    if (current.isNotEmpty) {
      result.add(current.toString().trim());
    }
    return result;
  }

  /// Gom các segments thành các lô (batch chunks) có kích thước vừa phải (~3000 ký tự)
  static List<List<TranslationSegment>> createBatches(
    List<TranslationSegment> segments, {
    int maxCharsPerBatch = 3500,
  }) {
    final batches = <List<TranslationSegment>>[];
    var currentBatch = <TranslationSegment>[];
    var currentChars = 0;

    for (final seg in segments) {
      if (currentChars + seg.sourceText.length > maxCharsPerBatch && currentBatch.isNotEmpty) {
        batches.add(currentBatch);
        currentBatch = [];
        currentChars = 0;
      }
      currentBatch.add(seg);
      currentChars += seg.sourceText.length;
    }

    if (currentBatch.isNotEmpty) {
      batches.add(currentBatch);
    }

    return batches;
  }
}
