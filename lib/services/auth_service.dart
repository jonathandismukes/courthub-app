import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hoopsight/models/user_model.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/notification_service.dart';
import 'package:hoopsight/services/checkin_service.dart';
import 'package:hoopsight/services/review_service.dart';
import 'package:hoopsight/services/group_service.dart';
import 'package:hoopsight/services/game_service.dart';
import 'package:hoopsight/services/storage_service.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final UserService _userService = UserService();
  final NotificationService _notificationService = NotificationService();
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // Auxiliary services for cleanup
  final CheckInService _checkInService = CheckInService();
  final ReviewService _reviewService = ReviewService();
  final GroupService _groupService = GroupService();
  final GameService _gameService = GameService();
  final StorageService _storageService = StorageService();

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<AppUser?> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    try {
      final isTaken = await _userService.isDisplayNameTaken(displayName);
      if (isTaken) {
        throw Exception('Display name is already taken. Please choose another.');
      }

      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (credential.user != null) {
        await credential.user!.updateDisplayName(displayName);
        
        final appUser = AppUser(
          id: credential.user!.uid,
          email: email,
          displayName: displayName,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        
        await _userService.createUser(appUser);
        return appUser;
      }
      return null;
    } catch (e) {
      debugPrint('Sign up error: $e');
      rethrow;
    }
  }

  Future<AppUser?> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (credential.user != null) {
        return await _userService.getUser(credential.user!.uid);
      }
      return null;
    } catch (e) {
      debugPrint('Sign in error: $e');
      rethrow;
    }
  }

  Future<void> signOut() async {
    // Remove FCM token before signing out
    final user = _auth.currentUser;
    if (user != null) {
      await _notificationService.removeFCMToken(user.uid);
    }
    await _auth.signOut();
  }

  Future<void> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } catch (e) {
      debugPrint('Reset password error: $e');
      rethrow;
    }
  }

  /// Permanently deletes the current user's account and related data we collected.
  /// Order:
  /// 1) Remove FCM token
  /// 2) Best-effort purge of user-related content across Firestore and Storage
  /// 3) Delete Firestore user document
  /// 4) Delete Firebase Auth user
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // Best-effort: remove FCM token
      await _notificationService.removeFCMToken(user.uid);

      // Fetch a snapshot of the user's Firestore profile first (for photoUrl, etc.)
      final appUser = await _userService.getUser(user.uid);

      // Purge user-related data we collected
      await _purgeAllUserData(user.uid, appUser: appUser);

      // Delete Firestore profile and tokens subcollection (after purge)
      await _userService.deleteUser(user.uid);

      // Delete Firebase Auth user
      await user.delete();
    } on FirebaseAuthException catch (e) {
      // If requires-recent-login, bubble up so UI can prompt re-auth
      debugPrint('Delete account auth error: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      debugPrint('Delete account error: $e');
      rethrow;
    }
  }

  /// Removes or anonymizes user-authored data across collections.
  /// This aims to delete content authored by the user and remove their
  /// identifiers from other users' records (friends, blocks, groups, games).
  Future<void> _purgeAllUserData(String userId, {AppUser? appUser}) async {
    // Run independent cleanups in parallel where possible.
    final futures = <Future<void>>[];

    // 0) Delete user profile photo if we have the URL
    futures.add(_deleteUserProfilePhoto(appUser));

    // 1) Remove user's active and historical check-ins
    futures.add(_deleteUserCheckIns(userId));

    // 2) Delete reviews authored by user (and their attached photos)
    futures.add(_deleteUserReviews(userId));

    // 3) Delete reports filed by user (and their screenshots)
    futures.add(_deleteUserReports(userId));

    // 4) Remove user from other users' friends and blocks arrays
    futures.add(_removeReferencesFromOtherUsers(userId));

    // 5) Remove or update friend requests involving the user
    futures.add(_deleteFriendRequests(userId));

    // 6) Remove user from invites; delete invites they sent
    futures.add(_deleteOrUpdateInvites(userId));

    // 7) Games: delete games they organized; remove them from others' rosters
    futures.add(_cleanupGames(userId, appUser?.displayName));

    // 8) Groups: remove membership; transfer or delete groups they created; delete their messages
    futures.add(_cleanupGroupsAndMessages(userId, appUser?.displayName));

    await Future.wait(futures);
  }

  Future<void> _deleteUserProfilePhoto(AppUser? appUser) async {
    try {
      final photoUrl = appUser?.photoUrl;
      if (photoUrl != null && photoUrl.isNotEmpty) {
        await _storageService.deleteFile(photoUrl);
      }
    } catch (e) {
      debugPrint('Warning: failed to delete user profile photo: $e');
    }
  }

  Future<void> _deleteUserCheckIns(String userId) async {
    try {
      final snapshot = await _db
          .collection('checkins')
          .where('userId', isEqualTo: userId)
          .get();
      for (final d in snapshot.docs) {
        await _checkInService.deleteCheckIn(d.id);
      }
    } catch (e) {
      debugPrint('Warning: failed to delete check-ins for $userId: $e');
    }
  }

  Future<void> _deleteUserReviews(String userId) async {
    try {
      final snapshot = await _db
          .collection('reviews')
          .where('userId', isEqualTo: userId)
          .get();
      for (final d in snapshot.docs) {
        final data = d.data();
        final parkId = data['parkId'] as String? ?? '';
        final photoUrls = List<String>.from(data['photoUrls'] ?? const <String>[]);
        // Delete photos
        for (final url in photoUrls) {
          try {
            await _storageService.deleteFile(url);
          } catch (e) {
            debugPrint('Warning: failed to delete review photo: $e');
          }
        }
        // Delete review doc and update park rating
        await _reviewService.deleteReview(d.id, parkId);
      }
    } catch (e) {
      debugPrint('Warning: failed to delete reviews for $userId: $e');
    }
  }

  Future<void> _deleteUserReports(String userId) async {
    try {
      final snap = await _db
          .collection('reports')
          .where('reporterId', isEqualTo: userId)
          .get();
      for (final d in snap.docs) {
        final screenshotUrl = d.data()['screenshotUrl'] as String?;
        if (screenshotUrl != null && screenshotUrl.isNotEmpty) {
          try {
            await _storageService.deleteFile(screenshotUrl);
          } catch (e) {
            debugPrint('Warning: failed to delete report screenshot: $e');
          }
        }
        await d.reference.delete();
      }
    } catch (e) {
      debugPrint('Warning: failed to delete reports for $userId: $e');
    }
  }

  Future<void> _removeReferencesFromOtherUsers(String userId) async {
    try {
      // Remove from others' friendIds
      final friendsSnap = await _db
          .collection('users')
          .where('friendIds', arrayContains: userId)
          .get();
      for (final d in friendsSnap.docs) {
        await d.reference.update({'friendIds': FieldValue.arrayRemove([userId])});
      }
      // Remove from others' blockedUserIds
      final blocksSnap = await _db
          .collection('users')
          .where('blockedUserIds', arrayContains: userId)
          .get();
      for (final d in blocksSnap.docs) {
        await d.reference.update({'blockedUserIds': FieldValue.arrayRemove([userId])});
      }
    } catch (e) {
      debugPrint('Warning: failed to remove user from others\' lists: $e');
    }
  }

  Future<void> _deleteFriendRequests(String userId) async {
    try {
      final sent = await _db
          .collection('friend_requests')
          .where('senderId', isEqualTo: userId)
          .get();
      for (final d in sent.docs) {
        await d.reference.delete();
      }
      final received = await _db
          .collection('friend_requests')
          .where('receiverId', isEqualTo: userId)
          .get();
      for (final d in received.docs) {
        await d.reference.delete();
      }
    } catch (e) {
      debugPrint('Warning: failed to delete friend requests: $e');
    }
  }

  Future<void> _deleteOrUpdateInvites(String userId) async {
    try {
      // Delete invites sent by the user
      final sent = await _db
          .collection('invites')
          .where('senderId', isEqualTo: userId)
          .get();
      for (final d in sent.docs) {
        await d.reference.delete();
      }
      // Remove the user from invitedUserIds arrays
      final invited = await _db
          .collection('invites')
          .where('invitedUserIds', arrayContains: userId)
          .get();
      for (final d in invited.docs) {
        // We cannot reliably remove the name by value without user name; remove by index if parallel arrays
        // Instead, only remove userId from invitedUserIds. Names are best-effort.
        await d.reference.update({
          'invitedUserIds': FieldValue.arrayRemove([userId]),
        });
        // If no invited users remain, delete the invite
        final refreshed = await d.reference.get();
        final List<dynamic> remaining = refreshed.data()?['invitedUserIds'] ?? const <dynamic>[];
        if (remaining.isEmpty) {
          await d.reference.delete();
        }
      }
    } catch (e) {
      debugPrint('Warning: failed to cleanup invites: $e');
    }
  }

  Future<void> _cleanupGames(String userId, String? userName) async {
    try {
      // Delete games organized by the user
      final orgSnap = await _db
          .collection('games')
          .where('organizerId', isEqualTo: userId)
          .get();
      for (final d in orgSnap.docs) {
        await _gameService.deleteGame(d.id);
      }
      // Remove from games where they are a player
      final playerGames = await _gameService.getUserGames(userId);
      for (final game in playerGames) {
        try {
          await _gameService.leaveGame(game.id, userId, userName ?? '');
        } catch (_) {
          // Fallback direct update
          await _db.collection('games').doc(game.id).update({
            'playerIds': FieldValue.arrayRemove([userId]),
          });
        }
      }
    } catch (e) {
      debugPrint('Warning: failed to cleanup games: $e');
    }
  }

  Future<void> _cleanupGroupsAndMessages(String userId, String? userName) async {
    try {
      // Remove user from groups where they are a member
      final memberSnap = await _db
          .collection('groups')
          .where('memberIds', arrayContains: userId)
          .get();
      for (final d in memberSnap.docs) {
        await d.reference.update({
          'memberIds': FieldValue.arrayRemove([userId]),
          'memberNames': userName != null ? FieldValue.arrayRemove([userName]) : FieldValue.arrayRemove([]),
          'updatedAt': DateTime.now().toIso8601String(),
        });
      }

      // Handle groups created by the user: transfer ownership or delete if empty
      final creatorSnap = await _db
          .collection('groups')
          .where('creatorId', isEqualTo: userId)
          .get();
      for (final d in creatorSnap.docs) {
        final data = d.data();
        final memberIds = List<String>.from(data['memberIds'] ?? const <String>[]);
        // Remove creator id from memberIds if present
        memberIds.removeWhere((e) => e == userId);
        if (memberIds.isEmpty) {
          // No members remain: delete group and its messages
          await _deleteGroupWithMessages(d.id);
        } else {
          // Transfer creator to first remaining member
          await d.reference.update({
            'creatorId': memberIds.first,
            'memberIds': memberIds,
            'memberNames': userName != null ? FieldValue.arrayRemove([userName]) : FieldValue.arrayRemove([]),
            'updatedAt': DateTime.now().toIso8601String(),
          });
        }
      }

      // Delete messages authored by the user across all groups
      final groupsSnap = await _db.collection('groups').get();
      for (final g in groupsSnap.docs) {
        final messagesSnap = await _db
            .collection('groups')
            .doc(g.id)
            .collection('messages')
            .where('senderId', isEqualTo: userId)
            .get();
        for (final m in messagesSnap.docs) {
          await m.reference.delete();
        }
      }
    } catch (e) {
      debugPrint('Warning: failed to cleanup groups/messages: $e');
    }
  }

  Future<void> _deleteGroupWithMessages(String groupId) async {
    try {
      // Delete messages subcollection
      final msgs = await _db.collection('groups').doc(groupId).collection('messages').get();
      for (final m in msgs.docs) {
        await m.reference.delete();
      }
      // Delete group doc
      await _groupService.deleteGroup(groupId);
    } catch (e) {
      debugPrint('Warning: failed deleting group $groupId: $e');
    }
  }

  Future<AppUser?> createAdminAccount({
    required String email,
    required String password,
    required String displayName,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (credential.user != null) {
        await credential.user!.updateDisplayName(displayName);
        
        final adminUser = AppUser(
          id: credential.user!.uid,
          email: email,
          displayName: displayName,
          bio: 'CourtHub Administrator',
          isAdmin: true,
          skillLevel: 'Advanced',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        
        await _userService.createUser(adminUser);
        return adminUser;
      }
      return null;
    } catch (e) {
      debugPrint('Create admin account error: $e');
      rethrow;
    }
  }

  Future<AppUser?> createFirestoreDocForCurrentUser({
    required String email,
    required String displayName,
    bool isAdmin = false,
  }) async {
    try {
      final users = await _userService.getUserByEmail(email);
      
      if (users.isEmpty) {
        final uid = await _getUserIdByEmail(email);
        
        if (uid == null) {
          throw Exception('Please log in first, then try setup again.');
        }
        
        final newUser = AppUser(
          id: uid,
          email: email,
          displayName: displayName,
          bio: '',
          isAdmin: false,
          skillLevel: 'Advanced',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        
        await _userService.createUser(newUser);
        return newUser;
      }
      return users.first;
    } catch (e) {
      debugPrint('Create Firestore doc error: $e');
      rethrow;
    }
  }

  Future<String?> _getUserIdByEmail(String email) async {
    try {
      final tempUser = _auth.currentUser;
      if (tempUser != null && tempUser.email?.toLowerCase() == email.toLowerCase()) {
        return tempUser.uid;
      }
      return null;
    } catch (e) {
      debugPrint('Error getting user ID: $e');
      return null;
    }
  }
}
