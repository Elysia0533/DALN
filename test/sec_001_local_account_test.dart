import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _localAccountsKey = 'local_accounts';
const _password = 'same-password';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('registering a new local account stores a password hash only', () async {
    await ApiService.registerWithBackend(
      email: 'new@example.com',
      password: _password,
      displayName: 'New User',
    );

    final account = await _singleStoredAccount();

    expect(account['password'], isNull);
    expect(account['passwordHash'], isA<String>());
    expect(account['passwordHash'], isNot(_password));
    expect(account['passwordHash'], startsWith(r'pbkdf2_sha256$v=1$i=120000$'));
  });

  test('login succeeds with the correct local password', () async {
    await ApiService.registerWithBackend(
      email: 'login@example.com',
      password: _password,
      displayName: 'Login User',
    );

    final user = await ApiService.loginWithBackend(
      email: 'login@example.com',
      password: _password,
    );

    expect(user.email, 'login@example.com');
  });

  test('login fails with the wrong local password', () async {
    await ApiService.registerWithBackend(
      email: 'wrong@example.com',
      password: _password,
      displayName: 'Wrong User',
    );

    expect(
      () => ApiService.loginWithBackend(
        email: 'wrong@example.com',
        password: 'wrong-password',
      ),
      throwsA(isA<Exception>()),
    );
  });

  test(
    'two local accounts with the same password get different hashes',
    () async {
      await ApiService.registerWithBackend(
        email: 'first@example.com',
        password: _password,
        displayName: 'First User',
      );
      await ApiService.registerWithBackend(
        email: 'second@example.com',
        password: _password,
        displayName: 'Second User',
      );

      final accounts = await _storedAccounts();

      expect(accounts, hasLength(2));
      expect(accounts[0]['passwordHash'], isNot(accounts[1]['passwordHash']));
    },
  );

  test('legacy plaintext account migrates after a correct login', () async {
    await _storeRawAccounts([
      {
        'id': 'local_legacy',
        'email': 'legacy@example.com',
        'displayName': 'Legacy User',
        'avatarUrl': '',
        'role': 'user',
        'emailVerified': true,
        'password': _password,
        'pendingCloudSync': true,
      },
    ]);

    final user = await ApiService.loginWithBackend(
      email: 'legacy@example.com',
      password: _password,
    );
    final account = await _singleStoredAccount();

    expect(user.email, 'legacy@example.com');
    expect(account['password'], isNull);
    expect(account['passwordHash'], isA<String>());
    expect(account['pendingCloudSync'], isTrue);
  });

  test('migrated legacy account can log in again', () async {
    await _storeRawAccounts([
      {
        'id': 'local_legacy_again',
        'email': 'legacy-again@example.com',
        'displayName': 'Legacy Again',
        'avatarUrl': '',
        'role': 'user',
        'emailVerified': true,
        'password': _password,
      },
    ]);

    await ApiService.loginWithBackend(
      email: 'legacy-again@example.com',
      password: _password,
    );
    final user = await ApiService.loginWithBackend(
      email: 'legacy-again@example.com',
      password: _password,
    );

    expect(user.email, 'legacy-again@example.com');
  });

  test('bad or incomplete local account data does not crash login', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_localAccountsKey, [
      'not-json',
      json.encode({'email': 'missing-fields@example.com'}),
      json.encode({
        'id': 'bad_hash',
        'email': 'bad-hash@example.com',
        'displayName': 'Bad Hash',
        'passwordHash': 'not-a-supported-hash',
      }),
    ]);

    expect(
      () => ApiService.loginWithBackend(
        email: 'bad-hash@example.com',
        password: _password,
      ),
      throwsA(isA<Exception>()),
    );
  });
}

Future<List<Map<String, dynamic>>> _storedAccounts() async {
  final prefs = await SharedPreferences.getInstance();
  final rawAccounts = prefs.getStringList(_localAccountsKey) ?? [];
  return rawAccounts
      .map((raw) => Map<String, dynamic>.from(json.decode(raw) as Map))
      .toList();
}

Future<Map<String, dynamic>> _singleStoredAccount() async {
  final accounts = await _storedAccounts();
  expect(accounts, hasLength(1));
  return accounts.single;
}

Future<void> _storeRawAccounts(List<Map<String, dynamic>> accounts) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(
    _localAccountsKey,
    accounts.map((account) => json.encode(account)).toList(),
  );
}
