import 'package:flutter/material.dart';
import 'lib/services/plugin/plugin_loader.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    print('Testing PluginLoader...');
    final paths = await PluginLoader.getInstalledPluginPaths();
    print('Installed plugin paths: $paths');
  } catch (e, st) {
    print('Error: $e');
    print(st);
  }
}
