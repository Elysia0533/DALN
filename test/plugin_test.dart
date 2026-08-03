import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/plugin/plugin_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Test PluginLoader getInstalledPluginPaths', () async {
    final paths = await PluginLoader.getInstalledPluginPaths();
    expect(paths, isA<List<String>>());
  });
}
