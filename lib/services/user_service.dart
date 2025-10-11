import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:hoopsight/models/user_model.dart';

class UserService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  // Use explicit region to avoid callable mismatches (backend defaults to us-central1)
  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  Future<void> createUser(AppUser user) async {
    final userData = user.toJson();
    userData['displayNameLower'] = user.displayName.trim().toLowerCase();
    await _db.collection('users').doc(user.id).set(userData);
  }

  Future<AppUser?> getUser(String userId) async {
    final doc = await _db.collection('users').doc(userId).get();
    if (doc.exists) {
      final data = doc.data()!;
      data['id'] = doc.id;
      return AppUser.fromJson(data);
    }
    return null;
  }

  Future<void> updateUser(AppUser user) async {
    final userData = user.toJson();
    userData['displayNameLower'] = user.displayName.trim().toLowerCase();
    // Never allow client-side elevation of admin flag via profile updates
    userData.remove('isAdmin');
    await _db.collection('users').doc(user.id).update(userData);
  }

  Future<void> addFavoritePark(String userId, String parkId) async {
    await _db.collection('users').doc(userId).update({
      'favoriteParkIds': FieldValue.arrayUnion([parkId]),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> removeFavoritePark(String userId, String parkId) async {
    await _db.collection('users').doc(userId).update({
      'favoriteParkIds': FieldValue.arrayRemove([parkId]),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> addFriend(String userId, String friendId) async {
    await _db.collection('users').doc(userId).update({
      'friendIds': FieldValue.arrayUnion([friendId]),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> removeFriend(String userId, String friendId) async {
    await _db.collection('users').doc(userId).update({
      'friendIds': FieldValue.arrayRemove([friendId]),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> blockUser(String userId, String targetUserId) async {
    await _db.collection('users').doc(userId).update({
      'blockedUserIds': FieldValue.arrayUnion([targetUserId]),
      'updatedAt': DateTime.now().toIso8601String(),
    });
    // Also remove friendship if any (one-way is enough; callers may remove both sides)
    await _db.collection('users').doc(userId).update({
      'friendIds': FieldValue.arrayRemove([targetUserId]),
    });
    await _db.collection('users').doc(targetUserId).update({
      'friendIds': FieldValue.arrayRemove([userId]),
    });
  }

  Future<void> unblockUser(String userId, String targetUserId) async {
    await _db.collection('users').doc(userId).update({
      'blockedUserIds': FieldValue.arrayRemove([targetUserId]),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  /// Returns true if either user has blocked the other.
  Future<bool> isEitherBlocked(String userA, String userB) async {
    final aDoc = await _db.collection('users').doc(userA).get();
    final bDoc = await _db.collection('users').doc(userB).get();
    if (!aDoc.exists || !bDoc.exists) return false;
    final a = aDoc.data()!;
    final b = bDoc.data()!;
    final aBlocks = List<String>.from(a['blockedUserIds'] ?? []);
    final bBlocks = List<String>.from(b['blockedUserIds'] ?? []);
    return aBlocks.contains(userB) || bBlocks.contains(userA);
  }

  Future<List<AppUser>> searchUsers(String query) async {
    // Case-insensitive search - fetch all users and filter in-memory
    // This approach works for small-to-medium user bases
    final snapshot = await _db.collection('users').limit(500).get();
    
    final lowerQuery = query.toLowerCase();
    final results = snapshot.docs
        .map((doc) {
          final data = doc.data();
          data['id'] = doc.id;
          return AppUser.fromJson(data);
        })
        .where((user) {
          final displayNameLower = user.displayName.toLowerCase();
          final emailLower = user.email.toLowerCase();
          return displayNameLower.contains(lowerQuery) || 
                 emailLower.contains(lowerQuery);
        })
        .take(20)
        .toList();

    return results;
  }

  Future<List<AppUser>> getFriends(List<String> friendIds) async {
    if (friendIds.isEmpty) return [];
    
    final snapshot = await _db
        .collection('users')
        .where(FieldPath.documentId, whereIn: friendIds)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return AppUser.fromJson(data);
    }).toList();
  }

  Future<void> promoteToAdmin(String userId) async {
    await _db.collection('users').doc(userId).update({
      'isAdmin': true,
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<List<AppUser>> getUserByEmail(String email) async {
    final snapshot = await _db
        .collection('users')
        .where('email', isEqualTo: email)
        .limit(1)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return AppUser.fromJson(data);
    }).toList();
  }

  Future<bool> isDisplayNameTaken(String displayName, {String? excludeUserId}) async {
    final lowerName = displayName.trim().toLowerCase();
    final snapshot = await _db
        .collection('users')
        .where('displayNameLower', isEqualTo: lowerName)
        .limit(1)
        .get();
    
    if (snapshot.docs.isEmpty) return false;
    if (excludeUserId != null && snapshot.docs.first.id == excludeUserId) return false;
    return true;
  }

  Future<void> toggleFavoriteNotification(String userId, String parkId, bool enabled) async {
    await _db.collection('users').doc(userId).update({
      'favoriteNotifications.$parkId': enabled,
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  /// Enable/disable notifications for a specific group
  Future<void> toggleGroupNotification(String userId, String groupId, bool enabled) async {
    await _db.collection('users').doc(userId).update({
      'groupNotifications.$groupId': enabled,
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  /// Returns the user's group notification map, or empty if not set
  Future<Map<String, bool>> getGroupNotifications(String userId) async {
    final doc = await _db.collection('users').doc(userId).get();
    if (doc.exists) {
      final data = doc.data()!;
      final raw = data['groupNotifications'];
      if (raw is Map<String, dynamic>) {
        return raw.map((k, v) => MapEntry(k, (v as bool?) ?? false));
      }
    }
    return {};
  }

  /// Search users by phone numbers (for contact syncing)
  Future<List<AppUser>> getUsersByPhoneNumbers(List<String> phoneNumbers) async {
    if (phoneNumbers.isEmpty) return [];
    
    // Firestore 'in' query supports up to 10 items
    // Split into batches if needed
    final batches = <List<String>>[];
    for (int i = 0; i < phoneNumbers.length; i += 10) {
      batches.add(phoneNumbers.sublist(i, (i + 10 > phoneNumbers.length) ? phoneNumbers.length : i + 10));
    }
    
    final results = <AppUser>[];
    for (final batch in batches) {
      final snapshot = await _db
          .collection('users')
          .where('phoneNumber', whereIn: batch)
          .get();
      
      results.addAll(snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return AppUser.fromJson(data);
      }));
    }
    
    return results;
  }

  /// Get user by phone number
  Future<AppUser?> getUserByPhoneNumber(String phoneNumber) async {
    final snapshot = await _db
        .collection('users')
        .where('phoneNumber', isEqualTo: phoneNumber)
        .limit(1)
        .get();
    
    if (snapshot.docs.isNotEmpty) {
      final data = snapshot.docs.first.data();
      data['id'] = snapshot.docs.first.id;
      return AppUser.fromJson(data);
    }
    return null;
  }

  /// Deletes a user's Firestore document and known subcollections.
  /// Note: This performs a best-effort cleanup and focuses on the user's
  /// profile document and FCM tokens. References in other collections
  /// (e.g., friends' lists) are not removed here.
  Future<void> deleteUser(String userId) async {
    // Delete tokens subcollection (if present)
    try {
      final tokensSnap = await _db.collection('users').doc(userId).collection('tokens').get();
      for (final doc in tokensSnap.docs) {
        await doc.reference.delete();
      }
    } catch (e) {
      // Non-fatal; continue deleting main user doc
      debugPrint('Warning: failed deleting tokens for user $userId: $e');
    }

    // Delete the user document
    await _db.collection('users').doc(userId).delete();
  }

  /// Owner-only maintenance: strips admin from all users except the configured owner.
  /// This calls the backend callable 'stripNonOwnerAdmins'.
  /// Returns the number of users that had admin revoked.
  Future<int> stripNonOwnerAdmins() async {
    try {
      final callable = _functions.httpsCallable('stripNonOwnerAdmins');
      final result = await callable.call();
      final data = result.data;
      // The function returns { stripped: <int> } but on web this may arrive
      // as a fixnum.Int64 which does not support toInt under dart2js.
      // Handle int, num, string, and Int64-like objects robustly.
      if (data is Map) {
        final v = data['stripped'];
        if (v is int) return v;
        if (v is num) return v.round();
        // Fallback: parse via string to avoid Int64 accessor issues on web
        final parsed = int.tryParse(v?.toString() ?? '');
        if (parsed != null) return parsed;
      }
      return 0;
    } on FirebaseFunctionsException catch (e) {
      // Surface precise code/message upstream for better diagnostics
      final code = e.code;
      final msg = e.message ?? 'No message';
      final details = e.details;
      debugPrint('stripNonOwnerAdmins failed: code=$code, message=$msg, details=$details');
      // Attempt a safe client-side fallback using Firestore if the caller is the owner.
      // This relies on Firestore rules allowing only the owner UID.
      try {
        final count = await _stripNonOwnerAdminsClientSide();
        debugPrint('Client-side admin cleanup succeeded, stripped=$count');
        return count;
      } catch (fallbackError) {
        debugPrint('Client-side admin cleanup failed: $fallbackError');
        throw '[firebase_functions/$code] $msg';
      }
    }
  }

  /// Client-side fallback: as the owner user, demote any non-owner admins directly via Firestore.
  /// Returns the number of accounts updated. Requires rules to allow only owner.
  Future<int> _stripNonOwnerAdminsClientSide() async {
    // Owner UID provided by app owner
    const ownerUid = '9pUPvGV3QpTy202M09Y4ZaOU8S92';
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid == null) {
      throw 'Not signed in';
    }
    if (currentUid != ownerUid) {
      throw 'Only the owner can run this';
    }

    // Fetch all users with isAdmin == true
    final snap = await _db
        .collection('users')
        .where('isAdmin', isEqualTo: true)
        .limit(500)
        .get();

    if (snap.docs.isEmpty) return 0;

    int updated = 0;
    WriteBatch? batch;
    int ops = 0;
    void commitNewBatch() {
      batch = _db.batch();
      ops = 0;
    }

    commitNewBatch();
    for (final doc in snap.docs) {
      if (doc.id == ownerUid) continue; // keep owner as admin
      batch!.update(doc.reference, {
        'isAdmin': false,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      updated++;
      ops++;
      if (ops >= 450) { // stay well under the 500 writes/batch limit
        await batch!.commit();
        commitNewBatch();
      }
    }
    if (ops > 0) {
      await batch!.commit();
    }
    return updated;
  }
}
