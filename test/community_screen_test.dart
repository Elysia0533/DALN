import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:online_story_reader/screens/community_screen.dart';
import 'package:online_story_reader/theme/user_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('CommunityScreen mounts without crashing as guest',
      (tester) async {
    final userProvider = UserProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<UserProvider>.value(value: userProvider),
        ],
        child: const MaterialApp(
          home: CommunityScreen(),
        ),
      ),
    );

    expect(find.text('Cộng đồng'), findsOneWidget);
    expect(find.text('Khách'), findsOneWidget);
    expect(find.text('Đăng nhập ở tab Cá nhân để gửi tin nhắn.'), findsOneWidget);
  });
}
