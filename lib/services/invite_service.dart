import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hoopsight/models/invite_model.dart';
import 'package:hoopsight/services/notification_service.dart';

class InviteService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final NotificationService _notificationService = NotificationService();

  Future<void> sendGameInvites(GameInvite invite) async {
    await _db.collection('invites').doc(invite.id).set(invite.toJson());

    for (final userId in invite.invitedUserIds) {
      if (invite.type == InviteType.scheduledGame) {
        await _notificationService.sendGameInviteNotification(
          userId,
          invite.senderName,
          invite.parkName,
          invite.scheduledTime,
        );
      } else {
        await _notificationService.sendNowPlayingNotification(
          userId,
          invite.senderName,
          invite.parkName,
          invite.courtNumber,
        );
      }
    }
  }

  Future<List<GameInvite>> getUserInvites(String userId) async {
    final snapshot = await _db
        .collection('invites')
        .where('invitedUserIds', arrayContains: userId)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return GameInvite.fromJson(data);
    }).toList();
  }

  Future<void> deleteInvite(String inviteId) async {
    await _db.collection('invites').doc(inviteId).delete();
  }
}
