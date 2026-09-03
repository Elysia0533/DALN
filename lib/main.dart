import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/splash_screen.dart';
import 'theme/theme_provider.dart';
import 'theme/reading_settings_provider.dart';
import 'theme/user_provider.dart';
import 'services/api_service.dart';
import 'services/firebase_backend_service.dart';
import 'utils/app_performance_logger.dart';

void main() async {
  AppPerformanceLogger.startTracking();
  WidgetsFlutterBinding.ensureInitialized();
  AppPerformanceLogger.log('WidgetsBinding initialized');

  await FirebaseBackendService.initialize();
  AppPerformanceLogger.log(
    FirebaseBackendService.isInitialized
        ? 'Firebase initialized'
        : 'Firebase unavailable',
  );

  // Defer heavy offline story initialization to background after runApp
  unawaited(
    ApiService.initOfflineStories()
        .then((_) {
          AppPerformanceLogger.log('Background offline stories init complete');
        })
        .catchError((e) {
          debugPrint('Background offline stories init error: $e');
        }),
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => ReadingSettingsProvider()),
        ChangeNotifierProvider(create: (_) => UserProvider()),
      ],
      child: const MyApp(),
    ),
  );
  AppPerformanceLogger.log('runApp executed - First UI paint initiated');
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp(
          title: 'vBook',
          debugShowCheckedModeBanner: false,
          theme: ThemeProvider.lightTheme,
          darkTheme: ThemeProvider.darkTheme,
          themeMode: themeProvider.themeMode,
          home: const SplashScreen(),
        );
      },
    );
  }
}
