import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hoopsight/models/group_message_model.dart';

class GroupChatService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _messagesCol(String groupId) =>
      _db.collection('groups').doc(groupId).collection('messages');

  Stream<List<GroupMessage>> watchMessages(String groupId, {int limit = 100}) {
    return _messagesCol(groupId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map((d) {
              final data = d.data();
              data['id'] = d.id;
              data['groupId'] = groupId;
              return GroupMessage.fromJson(data);
            }).toList());
  }

  Future<void> sendMessage(String groupId, GroupMessage message) async {
    final doc = _messagesCol(groupId).doc(message.id);
    await doc.set(message.toJson());
  }

  Future<void> deleteMessage(String groupId, String messageId) async {
    await _messagesCol(groupId).doc(messageId).update({
      'isDeleted': true,
      'text': '[deleted]',
    });
  }
}
