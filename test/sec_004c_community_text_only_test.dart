import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/community_message.dart';
import 'package:online_story_reader/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _authTokenKey = 'firebase_auth_token';
const _authUserKey = 'firebase_auth_user';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      _authTokenKey: 'local_user',
      _authUserKey: json.encode({
        'id': 'local_user',
        'email': 'local@example.com',
        'displayName': 'Local User',
        'avatarUrl': '',
        'role': 'admin',
        'emailVerified': true,
      }),
    });
  });

  test('local community sends text messages normally', () async {
    final message = await ApiService.sendCommunityMessage('  hello  ');

    expect(message.text, 'hello');
    expect(message.attachmentPath, isEmpty);
    expect(message.attachmentType, isEmpty);
  });

  test('local community rejects whitespace-only text', () async {
    expect(
      () => ApiService.sendCommunityMessage('   '),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Tin nhắn không được để trống.'),
        ),
      ),
    );
  });

  test('local community service guard rejects attachment calls', () async {
    expect(
      () => ApiService.sendCommunityMessage(
        'hello',
        attachmentType: 'image',
        attachmentPath: '/storage/emulated/0/private.png',
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('Tệp đính kèm chưa được hỗ trợ.'),
        ),
      ),
    );
  });

  test(
    'legacy community model keeps optional attachment fields for parsing',
    () {
      final message = CommunityMessage.fromJson({
        'id': 'legacy',
        'userId': 'user',
        'displayName': 'User',
        'text': '',
        'attachmentType': 'image',
        'attachmentPath': r'C:\Users\OS\private.png',
      });

      expect(message.text, isEmpty);
      expect(message.attachmentType, 'image');
      expect(message.attachmentPath, isNotEmpty);
    },
  );
}
