import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/features/translator_bot/core/providers/translation_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('GeminiTranslationProvider API Key and Model Tests', () {
    test('isValidKeyFormat validates Google AI Studio key format accurately', () {
      final legacyKey = 'AIzaSy' + 'FakeTestingKeyPurposesOnly1234567';
      expect(legacyKey.length, 39);
      expect(GeminiTranslationProvider.isValidKeyFormat(legacyKey), isTrue);

      // Newest Google AI Studio Auth Key format starting with AQ.
      final modernKey = 'AQ.' + 'MockTestingKeyForGoogleAiStudio1234567890';
      expect(GeminiTranslationProvider.isValidKeyFormat(modernKey), isTrue);

      // Invalid: empty or too short
      expect(GeminiTranslationProvider.isValidKeyFormat(''), isFalse);
      expect(GeminiTranslationProvider.isValidKeyFormat('AIzaSyShort'), isFalse);
      expect(GeminiTranslationProvider.isValidKeyFormat('AQ.short'), isFalse);
      expect(GeminiTranslationProvider.isValidKeyFormat('random_invalid_string'), isFalse);
    });

    test('resolveEffectiveKey resolves from SharedPreferences when saved', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ellie_gemini_api_key',
        'AIzaSyCustomKeyFromPrefs123456789012345',
      );

      final key = await GeminiTranslationProvider.resolveEffectiveKey();
      expect(key, 'AIzaSyCustomKeyFromPrefs123456789012345');
    });

    test('fromPreferences normalizes deprecated models to gemini-3.8-flash', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ellie_gemini_model', 'gemini-2.0-flash');

      final provider = await GeminiTranslationProvider.fromPreferences();
      expect(provider.modelName, 'gemini-3.8-flash');
    });
  });
}
