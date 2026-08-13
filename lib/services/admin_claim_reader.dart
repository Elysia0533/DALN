import 'dart:async';

import 'firebase_backend_service.dart';

enum AdminClaimStatus { loading, admin, nonAdmin, error }

abstract class AdminClaimReader {
  Stream<String?> get userIdChanges;
  String? get currentUserId;
  Future<Map<String, dynamic>?> readClaims({required bool forceRefresh});
}

class FirebaseAdminClaimReader implements AdminClaimReader {
  const FirebaseAdminClaimReader();

  @override
  Stream<String?> get userIdChanges => FirebaseBackendService.idTokenUidChanges;

  @override
  String? get currentUserId => FirebaseBackendService.currentAuthUserId;

  @override
  Future<Map<String, dynamic>?> readClaims({required bool forceRefresh}) {
    return FirebaseBackendService.readCurrentTokenClaims(
      forceRefresh: forceRefresh,
    );
  }
}

bool hasBooleanAdminClaim(Map<String, dynamic>? claims) {
  final value = claims?['admin'];
  return value is bool && value == true;
}
