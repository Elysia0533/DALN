import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/plugin_info.dart';
import '../services/extension_service.dart';
import '../utils/app_performance_logger.dart';
import 'home_screen.dart';
import 'source_browse_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleStartupNavigation();
    });
  }

  Future<void> _handleStartupNavigation() async {
    if (!mounted) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final lastExtId = prefs.getString('last_active_extension_id');
      if (lastExtId != null && lastExtId.isNotEmpty) {
        final installed = await ExtensionService.getInstalledPlugins();
        PluginInfo? targetPlugin;
        for (final p in installed) {
          if (p.id == lastExtId) {
            targetPlugin = p;
            break;
          }
        }
        if (targetPlugin != null && mounted) {
          AppPerformanceLogger.log(
            'SplashScreen -> Auto-opening last active extension: ${targetPlugin.name}',
          );
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => SourceBrowseScreen(
                plugin: targetPlugin!,
                isStartupExtension: true,
              ),
            ),
          );
          return;
        }
      }
    } catch (e) {
      debugPrint('[SplashScreen] Error checking last active extension: $e');
    }

    if (!mounted) return;
    AppPerformanceLogger.log(
      'SplashScreen first frame rendered -> Transitioning to HomeScreen',
    );
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Image.asset(
            'assets/branding/app_icon.png',
            width: 160,
            height: 160,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}
