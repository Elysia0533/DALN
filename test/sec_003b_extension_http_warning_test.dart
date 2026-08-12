import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/screens/extension_screen.dart';
import 'package:online_story_reader/services/extension_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('extension URL validation', () {
    test('accepts HTTPS without cleartext warning state', () {
      final result = ExtensionService.validateUserProvidedUrl(
        'https://example.com/plugin.json',
      );

      expect(result.isValid, isTrue);
      expect(result.isCleartext, isFalse);
      expect(result.url, 'https://example.com/plugin.json');
      expect(result.host, 'example.com');
    });

    test('accepts HTTP and preserves the cleartext URL', () {
      final result = ExtensionService.validateUserProvidedUrl(
        'http://example.com/extension.zip',
      );

      expect(result.isValid, isTrue);
      expect(result.isCleartext, isTrue);
      expect(result.url, 'http://example.com/extension.zip');
      expect(result.host, 'example.com');
    });

    test('rejects malformed, unsupported, hostless, and credential URLs', () {
      final cases = [
        'https://',
        'https://exa mple.com/plugin.json',
        'ftp://example.com/plugin.json',
        'file:///tmp/plugin.zip',
        'http://user:pass@example.com/plugin.zip',
      ];

      for (final input in cases) {
        final result = ExtensionService.validateUserProvidedUrl(input);
        expect(result.isValid, isFalse, reason: input);
        expect(result.errorMessage, isNotEmpty, reason: input);
      }
    });

    test('invalid registry URL is not saved', () async {
      SharedPreferences.setMockInitialValues({});

      await expectLater(
        ExtensionService.addRegistryUrl('ftp://example.com/plugin.json'),
        throwsA(isA<Exception>()),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('plugin_registries'), isNull);
    });

    test('direct ZIP install rejects unsupported scheme before download', () {
      return expectLater(
        ExtensionService.installFromZipUrl('file:///tmp/extension.zip'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('cleartext warning dialog', () {
    testWidgets('HTTPS input continues without showing a warning', (
      tester,
    ) async {
      ExtensionUrlValidationResult? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await confirmUserProvidedExtensionUrl(
                  context,
                  'https://example.com/plugin.json',
                  actionLabel: 'Tiep tuc',
                );
              },
              child: const Text('Confirm URL'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Confirm URL'));
      await tester.pumpAndSettle();

      expect(find.text('Canh bao ket noi HTTP'), findsNothing);
      expect(result, isNotNull);
      expect(result!.url, 'https://example.com/plugin.json');
      expect(result!.isCleartext, isFalse);
    });

    testWidgets('HTTP input cancel returns null before continuing', (
      tester,
    ) async {
      ExtensionUrlValidationResult? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await confirmUserProvidedExtensionUrl(
                  context,
                  'http://example.com/plugin.json',
                  actionLabel: 'Tiep tuc',
                );
              },
              child: const Text('Confirm URL'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Confirm URL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Huy'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('allows cancelling an HTTP action', (tester) async {
      bool? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showExtensionCleartextWarningDialog(
                  context,
                  host: 'example.com',
                  actionLabel: 'Tiep tuc',
                );
              },
              child: const Text('Open warning'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open warning'));
      await tester.pumpAndSettle();

      expect(find.text('Canh bao ket noi HTTP'), findsOneWidget);
      expect(find.textContaining('co the bi doc'), findsOneWidget);

      await tester.tap(find.text('Huy'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });

    testWidgets('allows explicitly continuing an HTTP action', (tester) async {
      bool? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showExtensionCleartextWarningDialog(
                  context,
                  host: 'example.com',
                  actionLabel: 'Tiep tuc',
                );
              },
              child: const Text('Open warning'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open warning'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tiep tuc'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });
  });
}
