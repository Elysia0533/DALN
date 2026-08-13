import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/admin_claim_reader.dart';
import 'package:online_story_reader/theme/user_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('claim evaluator accepts only boolean admin true', () {
    expect(hasBooleanAdminClaim({'admin': true}), isTrue);
    expect(hasBooleanAdminClaim({'admin': false}), isFalse);
    expect(hasBooleanAdminClaim({}), isFalse);
    expect(hasBooleanAdminClaim({'admin': 'true'}), isFalse);
    expect(hasBooleanAdminClaim({'admin': 1}), isFalse);
    expect(hasBooleanAdminClaim(null), isFalse);
  });

  test('signed-out user is non-admin', () async {
    final reader = _FakeAdminClaimReader();
    final provider = UserProvider(adminClaimReader: reader);
    addTearDown(provider.dispose);

    reader.emit(null);
    await _flush();

    expect(provider.isAdmin, isFalse);
    expect(provider.adminClaimStatus, AdminClaimStatus.nonAdmin);
  });

  test('admin true claim enables admin state', () async {
    final reader = _FakeAdminClaimReader(claims: {'admin': true});
    final provider = UserProvider(adminClaimReader: reader);
    addTearDown(provider.dispose);

    reader.emit('alice');
    await _flush();

    expect(provider.isAdmin, isTrue);
    expect(provider.adminClaimStatus, AdminClaimStatus.admin);
  });

  test(
    'missing, false, string, and numeric admin claims are non-admin',
    () async {
      for (final claims in [
        <String, dynamic>{},
        {'admin': false},
        {'admin': 'true'},
        {'admin': 1},
      ]) {
        final reader = _FakeAdminClaimReader(claims: claims);
        final provider = UserProvider(adminClaimReader: reader);

        reader.emit('alice');
        await _flush();

        expect(provider.isAdmin, isFalse);
        expect(provider.adminClaimStatus, AdminClaimStatus.nonAdmin);
        provider.dispose();
      }
    },
  );

  test(
    'token read failure fails closed as non-admin with error state',
    () async {
      final reader = _FakeAdminClaimReader(failure: Exception('network'));
      final provider = UserProvider(adminClaimReader: reader);
      addTearDown(provider.dispose);

      reader.emit('alice');
      await _flush();

      expect(provider.isAdmin, isFalse);
      expect(provider.adminClaimStatus, AdminClaimStatus.error);
    },
  );

  test('sign-out clears previous admin state immediately', () async {
    final reader = _FakeAdminClaimReader(claims: {'admin': true});
    final provider = UserProvider(adminClaimReader: reader);
    addTearDown(provider.dispose);

    reader.emit('alice');
    await _flush();
    expect(provider.isAdmin, isTrue);

    reader.emit(null);
    await _flush();

    expect(provider.isAdmin, isFalse);
    expect(provider.adminClaimStatus, AdminClaimStatus.nonAdmin);
  });

  test(
    'account switch ignores stale async result from previous account',
    () async {
      final aliceCompleter = Completer<Map<String, dynamic>?>();
      final reader = _FakeAdminClaimReader(
        claimsForUid: {
          'alice': aliceCompleter.future,
          'bob': Future.value({'admin': false}),
        },
      );
      final provider = UserProvider(adminClaimReader: reader);
      addTearDown(provider.dispose);

      reader.emit('alice');
      await _flush();
      reader.emit('bob');
      await _flush();
      aliceCompleter.complete({'admin': true});
      await _flush();

      expect(provider.isAdmin, isFalse);
      expect(provider.adminClaimStatus, AdminClaimStatus.nonAdmin);
    },
  );

  test(
    'force refresh reads claims once for each explicit refresh request',
    () async {
      final reader = _FakeAdminClaimReader(claims: {'admin': true});
      final provider = UserProvider(adminClaimReader: reader);
      addTearDown(provider.dispose);

      reader.emit('alice');
      await _flush();
      reader.resetCounts();

      await provider.refreshAdminClaim();

      expect(reader.forceRefreshReads, 1);
      expect(reader.normalReads, 0);
      expect(provider.isAdmin, isTrue);
    },
  );
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeAdminClaimReader implements AdminClaimReader {
  final _controller = StreamController<String?>.broadcast();
  final Map<String, Future<Map<String, dynamic>?>> claimsForUid;
  Map<String, dynamic>? claims;
  Object? failure;
  String? _currentUserId;
  int forceRefreshReads = 0;
  int normalReads = 0;

  _FakeAdminClaimReader({
    this.claims,
    this.failure,
    this.claimsForUid = const {},
  });

  void emit(String? uid) {
    _currentUserId = uid;
    _controller.add(uid);
  }

  void resetCounts() {
    forceRefreshReads = 0;
    normalReads = 0;
  }

  @override
  String? get currentUserId => _currentUserId;

  @override
  Stream<String?> get userIdChanges => _controller.stream;

  @override
  Future<Map<String, dynamic>?> readClaims({required bool forceRefresh}) async {
    if (forceRefresh) {
      forceRefreshReads += 1;
    } else {
      normalReads += 1;
    }
    if (failure != null) throw failure!;
    final uid = _currentUserId;
    if (uid != null && claimsForUid.containsKey(uid)) {
      return claimsForUid[uid]!;
    }
    return claims;
  }
}
