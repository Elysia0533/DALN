import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/features/translator_bot/core/engine/orchestrator.dart';
import 'package:online_story_reader/features/translator_bot/core/models/translation_models.dart';
import 'package:online_story_reader/features/translator_bot/core/providers/translation_provider.dart';
import 'package:online_story_reader/features/translator_bot/core/storage/bot_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockLearningTranslationProvider implements TranslationProvider {
  @override
  String get id => 'mock_provider';

  @override
  String get name => 'Mock Provider';

  @override
  String modelName = 'mock-model';

  @override
  String apiKey = 'mock-key';

  @override
  Future<TranslationBatchResponse> translateBatch({
    required List<TranslationSegment> segments,
    required TranslationProfile profile,
    required List<GlossaryTerm> glossary,
    required List<AddressRule> addressRules,
    required String rollingSummary,
    required List<TranslationSegment> recentContextSegments,
  }) async {
    return TranslationBatchResponse(
      segments: segments
          .map((s) => SegmentTranslationResult(id: s.id, text: 'Dịch: ${s.sourceText}'))
          .toList(),
    );
  }

  @override
  Future<List<GlossaryTerm>> extractGlossary({
    required String text,
    required String profileId,
    required String srcLang,
  }) async {
    return [];
  }

  @override
  Future<String> distillStyleGuide({required String sampleVietnameseText}) async {
    return '- Phong cách mượt mà';
  }

  @override
  Future<String> chatWithEllie({
    required String userMessage,
    required List<Map<String, String>> conversationHistory,
  }) async {
    return 'Ellie chào bạn!';
  }

  @override
  Future<TranslationLearningResult> learnFromUserEdit({
    required String sourceText,
    required String originalTranslatedText,
    required String userEditedText,
    required TranslationProfile profile,
  }) async {
    return TranslationLearningResult(
      newTerms: [
        GlossaryTerm(
          id: 'term_1',
          profileId: profile.id,
          source: 'Tang San',
          target: 'Đường Tam',
          type: GlossaryType.character,
          isConfirmed: true,
        ),
      ],
      newAddressRules: [
        AddressRule(
          id: 'rule_1',
          profileId: profile.id,
          speaker: 'Đường Tam',
          listener: 'Tiểu Vũ',
          selfRef: 'Ca ca',
          otherRef: 'Tiểu Vũ',
          context: 'Thân mật',
        ),
      ],
      styleLesson: 'Sử dụng xưng hô huynh muội thân thiết',
      summary: 'Đã học tên Đường Tam và cách xưng hô với Tiểu Vũ',
    );
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Translation Presets Tests', () {
    test('Core principles contain literary translation rules', () {
      expect(TranslationPresets.corePrinciples, contains('VĂN PHONG VĂN HỌC THUẦN VIỆT'));
      expect(TranslationPresets.corePrinciples, contains('TRUNG THÀNH VỚI NGUYÊN TÁC'));
      expect(TranslationPresets.corePrinciples, contains('TUÂN THỦ GLOSSARY & XƯNG HÔ'));
    });

    test('Preset guidelines return appropriate domain rules', () {
      final wuxia = TranslationPresets.getPresetGuidelines('wuxia');
      expect(wuxia, contains('TIÊN HIỆP'));
      expect(wuxia, contains('Ta - Ngươi'));

      final ln = TranslationPresets.getPresetGuidelines('light_novel');
      expect(ln, contains('LIGHT NOVEL'));
      expect(ln, contains('Cậu - Tớ'));

      final fantasy = TranslationPresets.getPresetGuidelines('fantasy');
      expect(fantasy, contains('FANTASY'));

      final modern = TranslationPresets.getPresetGuidelines('modern');
      expect(modern, contains('HIỆN ĐẠI'));
    });
  });

  group('Orchestrator Self-Learning Tests', () {
    test('learnFromUserEditAndApply persists terms, rules, and style lessons', () async {
      final mockProvider = MockLearningTranslationProvider();
      final orchestrator = TranslationOrchestrator(
        provider: mockProvider,
        database: BotDatabase.instance,
      );

      final session = await orchestrator.createSessionFromText(
        text: 'Hello world.\n\nTang San meets Xiao Wu.',
        title: 'Test Novel Chapter 1',
        preset: 'wuxia',
      );

      final segments = await BotDatabase.instance.getSegments(session.id);
      expect(segments.length, greaterThanOrEqualTo(2));

      // Simulate initial translation
      await orchestrator.translatePreview(session: session, previewSegmentCount: 2);

      // Now user edits segment 2
      final targetSeg = segments[1];
      final learning = await orchestrator.learnFromUserEditAndApply(
        session: session,
        segmentId: targetSeg.id,
        userEditedText: 'Đường Tam gặp gỡ Tiểu Vũ.',
      );

      expect(learning.hasLearnings, isTrue);
      expect(learning.newTerms.length, equals(1));
      expect(learning.newTerms.first.target, equals('Đường Tam'));
      expect(learning.newAddressRules.length, equals(1));
      expect(learning.newAddressRules.first.selfRef, equals('Ca ca'));

      // Verify persisted in DB
      final savedTerms = await BotDatabase.instance.getTermsByProfile(session.profileId);
      expect(savedTerms.any((t) => t.target == 'Đường Tam'), isTrue);

      final savedRules = await BotDatabase.instance.getAddressRulesByProfile(session.profileId);
      expect(savedRules.any((r) => r.selfRef == 'Ca ca'), isTrue);

      final profile = await BotDatabase.instance.getProfile(session.profileId);
      expect(profile!.styleGuide, contains('Sử dụng xưng hô huynh muội thân thiết'));
    });
  });
}
