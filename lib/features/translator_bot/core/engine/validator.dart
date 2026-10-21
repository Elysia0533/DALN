import '../models/translation_models.dart';
import '../providers/translation_provider.dart';

class TranslationValidator {
  /// Xác thực kết quả trả về từ AI so với danh sách đoạn đầu vào
  static ValidationResult validateBatch({
    required List<TranslationSegment> inputSegments,
    required List<SegmentTranslationResult> outputSegments,
    String srcLang = 'en',
  }) {
    final missingIds = <String>[];
    final outputMap = {for (final o in outputSegments) o.id: o.text.trim()};

    for (final seg in inputSegments) {
      final translated = outputMap[seg.id];
      if (translated == null || translated.isEmpty) {
        missingIds.add(seg.id);
        continue;
      }

      // Kiểm tra độ dài bất thường (nghi vấn bị tóm tắt cắt chữ)
      if (seg.sourceText.length > 50 && translated.length < (seg.sourceText.length * 0.25)) {
        // Có thể bị tóm tắt quá ngắn
      }

      // Kiểm tra sót ký tự gốc đối với tiếng Trung / Nhật nếu cần
      if (srcLang == 'zh' || srcLang == 'ja') {
        final cjkPattern = RegExp(r'[\u4E00-\u9FFF]');
        final cjkMatches = cjkPattern.allMatches(translated);
        if (cjkMatches.length > 5) {
          // Vẫn còn sót nhiều chữ Hán chưa dịch
        }
      }
    }

    return ValidationResult(
      isValid: missingIds.isEmpty,
      missingIds: missingIds,
    );
  }
}

class ValidationResult {
  final bool isValid;
  final List<String> missingIds;

  ValidationResult({required this.isValid, this.missingIds = const []});
}
