import 'dart:async';
import '../models/translation_models.dart';
import '../providers/translation_provider.dart';
import '../storage/bot_database.dart';
import 'segmenter.dart';
import 'validator.dart';

class TranslationOrchestrator {
  final TranslationProvider provider;
  final BotDatabase db;

  TranslationOrchestrator({
    required this.provider,
    BotDatabase? database,
  }) : db = database ?? BotDatabase.instance;

  /// Khởi tạo phiên dịch từ văn bản thô
  Future<TranslationSession> createSessionFromText({
    required String text,
    required String title,
    String folderName = 'Chưa phân loại',
    String srcLang = 'en',
    String preset = 'modern',
    SessionKind kind = SessionKind.text,
    String sourceRef = '',
  }) async {
    final profileId = 'prof_${DateTime.now().millisecondsSinceEpoch}';
    final sessionId = 'sess_${DateTime.now().millisecondsSinceEpoch}';

    final profile = TranslationProfile(
      id: profileId,
      title: title,
      srcLang: srcLang,
      tgtLang: 'vi',
      preset: preset,
    );
    await db.saveProfile(profile);

    final session = TranslationSession(
      id: sessionId,
      profileId: profileId,
      folderName: folderName,
      chapterTitle: title,
      kind: kind,
      sourceRef: sourceRef,
      status: SessionStatus.temp, // Mặc định là temp
    );
    await db.saveSession(session);

    // Tách đoạn
    final segments = TextSegmenter.segmentText(text);
    await db.saveSegments(sessionId, segments);

    return session;
  }

  /// Dịch thử một đoạn ngắn đầu tiên (Preview ~ 500 từ / 2-3 đoạn đầu)
  Future<List<TranslationSegment>> translatePreview({
    required TranslationSession session,
    int previewSegmentCount = 3,
  }) async {
    final profile = await db.getProfile(session.profileId);
    if (profile == null) throw StateError('Không tìm thấy profile của truyện');

    final segments = await db.getSegments(session.id);
    if (segments.isEmpty) return [];

    final previewSegments = segments.take(previewSegmentCount).toList();
    final glossary = await db.getTermsByProfile(profile.id);
    final addressRules = await db.getAddressRulesByProfile(profile.id);

    final response = await provider.translateBatch(
      segments: previewSegments,
      profile: profile,
      glossary: glossary,
      addressRules: addressRules,
      rollingSummary: session.rollingSummary,
      recentContextSegments: const [],
    );

    final resultMap = {for (final s in response.segments) s.id: s.text};
    for (final seg in previewSegments) {
      if (resultMap.containsKey(seg.id)) {
        seg.translatedText = resultMap[seg.id]!;
        seg.state = SegmentState.done;
        await db.updateSegmentTranslation(session.id, seg.id, seg.translatedText, seg.state);
      }
    }

    // Tự động thêm terms mới phát hiện nếu có
    for (final term in response.newTerms) {
      await db.saveGlossaryTerm(term);
    }

    return previewSegments;
  }

  /// Ghi nhận phản hồi / sửa đổi từ người dùng sau vòng preview
  Future<void> recordPreviewFeedback({
    required TranslationSession session,
    required String segmentId,
    required String editedText,
    String? note,
  }) async {
    await db.updateSegmentTranslation(
      session.id,
      segmentId,
      editedText,
      SegmentState.edited,
    );

    // Nếu người dùng có ghi chú góp ý, cập nhật style guide của profile
    if (note != null && note.trim().isNotEmpty) {
      final profile = await db.getProfile(session.profileId);
      if (profile != null) {
        final updatedGuide = profile.styleGuide.isEmpty
            ? '- Góp ý của bạn: $note'
            : '${profile.styleGuide}\n- Góp ý: $note';
        profile.styleGuide = updatedGuide;
        await db.saveProfile(profile);
      }
    }
  }

  /// Người dùng sửa một câu dịch (trong preview hoặc khi đang đọc),
  /// AI so sánh và tự học các thuật ngữ, quan hệ xưng hô, văn phong
  /// để tự động cập nhật Database và Profile cho các lần dịch sau.
  Future<TranslationLearningResult> learnFromUserEditAndApply({
    required TranslationSession session,
    required String segmentId,
    required String userEditedText,
  }) async {
    final profile = await db.getProfile(session.profileId);
    if (profile == null) throw StateError('Không tìm thấy profile của truyện');

    final segments = await db.getSegments(session.id);
    final targetSegment = segments.firstWhere(
      (s) => s.id == segmentId,
      orElse: () => throw StateError('Không tìm thấy đoạn văn $segmentId'),
    );

    final originalTranslated = targetSegment.translatedText;

    // 1. Cập nhật đoạn văn trong cơ sở dữ liệu
    targetSegment.translatedText = userEditedText;
    targetSegment.state = SegmentState.edited;
    await db.updateSegmentTranslation(
      session.id,
      segmentId,
      userEditedText,
      SegmentState.edited,
    );

    // 2. Nếu nội dung sửa giống hệt ban đầu thì không cần phân tích
    if (originalTranslated.trim() == userEditedText.trim()) {
      return const TranslationLearningResult(summary: 'Đoạn văn không có thay đổi.');
    }

    // 3. AI so sánh và tự học
    final learning = await provider.learnFromUserEdit(
      sourceText: targetSegment.sourceText,
      originalTranslatedText: originalTranslated,
      userEditedText: userEditedText,
      profile: profile,
    );

    // 4. Lưu terms mới tự học
    for (final term in learning.newTerms) {
      await db.saveGlossaryTerm(term);
    }

    // 5. Lưu address rules mới tự học
    for (final rule in learning.newAddressRules) {
      await db.saveAddressRule(rule);
    }

    // 6. Cập nhật style guide nếu có bài học mới
    if (learning.styleLesson != null && learning.styleLesson!.trim().isNotEmpty) {
      final lesson = learning.styleLesson!.trim();
      final updatedGuide = profile.styleGuide.isEmpty
          ? '- Kinh nghiệm học được: $lesson'
          : '${profile.styleGuide}\n- Kinh nghiệm học được: $lesson';
      profile.styleGuide = updatedGuide;
      await db.saveProfile(profile);
    }

    return learning;
  }

  /// Dịch toàn bộ các đoạn còn lại theo batch có kiểm tra ngữ cảnh liên tục
  Stream<double> translateRemaining({
    required TranslationSession session,
  }) async* {
    final profile = await db.getProfile(session.profileId);
    if (profile == null) throw StateError('Không tìm thấy profile của truyện');

    final allSegments = await db.getSegments(session.id);
    final remainingSegments = allSegments.where((s) => s.state != SegmentState.done && s.state != SegmentState.edited).toList();

    if (remainingSegments.isEmpty) {
      yield 1.0;
      return;
    }

    final batches = TextSegmenter.createBatches(remainingSegments);
    int completedCount = allSegments.length - remainingSegments.length;

    var currentRollingSummary = session.rollingSummary;
    var recentContext = allSegments
        .where((s) => s.state == SegmentState.done || s.state == SegmentState.edited)
        .take(2)
        .toList();

    for (int i = 0; i < batches.length; i++) {
      final batch = batches[i];
      final glossary = await db.getTermsByProfile(profile.id);
      final addressRules = await db.getAddressRulesByProfile(profile.id);

      final response = await provider.translateBatch(
        segments: batch,
        profile: profile,
        glossary: glossary,
        addressRules: addressRules,
        rollingSummary: currentRollingSummary,
        recentContextSegments: recentContext,
      );

      // Xác thực kết quả
      TranslationValidator.validateBatch(
        inputSegments: batch,
        outputSegments: response.segments,
        srcLang: profile.srcLang,
      );

      // Cập nhật kết quả
      final resultMap = {for (final s in response.segments) s.id: s.text};
      for (final seg in batch) {
        final text = resultMap[seg.id] ?? '';
        seg.translatedText = text;
        seg.state = text.isNotEmpty ? SegmentState.done : SegmentState.error;
        await db.updateSegmentTranslation(session.id, seg.id, seg.translatedText, seg.state);
      }

      // Cập nhật tóm tắt ngữ cảnh cuộn
      if (response.summaryUpdate != null && response.summaryUpdate!.isNotEmpty) {
        currentRollingSummary = response.summaryUpdate!;
        session.rollingSummary = currentRollingSummary;
        await db.saveSession(session);
      }

      // Cập nhật terms mới
      for (final term in response.newTerms) {
        await db.saveGlossaryTerm(term);
      }

      recentContext = batch.take(2).toList();
      completedCount += batch.length;
      yield completedCount / allSegments.length;
    }

    yield 1.0;
  }
}
