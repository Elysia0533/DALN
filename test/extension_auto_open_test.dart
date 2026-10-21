import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:online_story_reader/screens/source_browse_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('last_active_extension_id is stored and cleared properly', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SourceBrowseScreen.prefKeyLastActiveExtension), isNull);

    // Save extension
    await prefs.setString(SourceBrowseScreen.prefKeyLastActiveExtension, 'docln');
    expect(prefs.getString(SourceBrowseScreen.prefKeyLastActiveExtension), 'docln');

    // Switch to another extension
    await prefs.setString(SourceBrowseScreen.prefKeyLastActiveExtension, 'truyenqq');
    expect(prefs.getString(SourceBrowseScreen.prefKeyLastActiveExtension), 'truyenqq');

    // Return to root interface clears the key
    await prefs.remove(SourceBrowseScreen.prefKeyLastActiveExtension);
    expect(prefs.getString(SourceBrowseScreen.prefKeyLastActiveExtension), isNull);
  });
}
