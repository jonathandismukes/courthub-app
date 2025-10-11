import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hoopsight/models/friend_request_model.dart';
import 'package:hoopsight/services/notification_service.dart';

class FriendService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final NotificationService _notificationService = NotificationService();

  Future<void> sendFriendRequest(String senderId, String senderName, String? senderPhotoUrl, String receiverId, String receiverName) async {
    // Prevent sending if either has blocked the other
    final senderDoc = await _db.collection('users').doc(senderId).get();
    final receiverDoc = await _db.collection('users').doc(receiverId).get();
    if (senderDoc.exists && receiverDoc.exists) {
      final sBlocked = List<String>.from(senderDoc.data()!['blockedUserIds'] ?? []);
      final rBlocked = List<String>.from(receiverDoc.data()!['blockedUserIds'] ?? []);
      if (sBlocked.contains(receiverId) || rBlocked.contains(senderId)) {
        throw Exception('Cannot send request: user is blocked');
      }
    }

    final existingRequest = await _db
        .collection('friend_requests')
        .where('senderId', isEqualTo: senderId)
        .where('receiverId', isEqualTo: receiverId)
        .where('status', isEqualTo: 'pending')
        .get();

    if (existingRequest.docs.isNotEmpty) {
      throw Exception('Friend request already sent');
    }

    final request = FriendRequest(
      id: '${senderId}_${receiverId}_${DateTime.now().millisecondsSinceEpoch}',
      senderId: senderId,
      senderName: senderName,
      senderPhotoUrl: senderPhotoUrl,
      receiverId: receiverId,
      receiverName: receiverName,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await _db.collection('friend_requests').doc(request.id).set(request.toJson());
    await _notificationService.sendFriendRequestNotification(receiverId, senderName);
  }

  Future<void> acceptFriendRequest(String requestId, String currentUserId) async {
    final doc = await _db.collection('friend_requests').doc(requestId).get();
    if (!doc.exists) return;

    final data = doc.data()!;
    data['id'] = doc.id;
    final request = FriendRequest.fromJson(data);
    
    await _db.collection('friend_requests').doc(requestId).update({
      'status': 'accepted',
      'updatedAt': DateTime.now().toIso8601String(),
    });

    await _db.collection('users').doc(request.senderId).update({
      'friendIds': FieldValue.arrayUnion([request.receiverId]),
    });

    await _db.collection('users').doc(request.receiverId).update({
      'friendIds': FieldValue.arrayUnion([request.senderId]),
    });
  }

  Future<void> rejectFriendRequest(String requestId) async {
    await _db.collection('friend_requests').doc(requestId).update({
      'status': 'rejected',
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> removeFriend(String userId, String friendId) async {
    await _db.collection('users').doc(userId).update({
      'friendIds': FieldValue.arrayRemove([friendId]),
    });

    await _db.collection('users').doc(friendId).update({
      'friendIds': FieldValue.arrayRemove([userId]),
    });
  }

  Future<List<FriendRequest>> getPendingRequests(String userId) async {
    final snapshot = await _db
        .collection('friend_requests')
        .where('receiverId', isEqualTo: userId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return FriendRequest.fromJson(data);
    }).toList();
  }

  Future<List<FriendRequest>> getSentRequests(String userId) async {
    final snapshot = await _db
        .collection('friend_requests')
        .where('senderId', isEqualTo: userId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return FriendRequest.fromJson(data);
    }).toList();
  }

  Stream<List<FriendRequest>> watchPendingRequests(String userId) {
    return _db
        .collection('friend_requests')
        .where('receiverId', isEqualTo: userId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map((doc) {
          final data = doc.data();
          data['id'] = doc.id;
          return FriendRequest.fromJson(data);
        }).toList());
  }
}
