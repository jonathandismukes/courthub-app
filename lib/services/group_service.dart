import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hoopsight/models/group_model.dart';

class GroupService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> createGroup(FriendGroup group) async {
    await _db.collection('groups').doc(group.id).set(group.toJson());
  }

  Future<void> updateGroup(FriendGroup group) async {
    await _db.collection('groups').doc(group.id).update(group.toJson());
  }

  Future<void> deleteGroup(String groupId) async {
    await _db.collection('groups').doc(groupId).delete();
  }

  Future<FriendGroup?> getGroup(String groupId) async {
    final doc = await _db.collection('groups').doc(groupId).get();
    if (doc.exists) {
      final data = doc.data()!;
      data['id'] = doc.id;
      return FriendGroup.fromJson(data);
    }
    return null;
  }

  Future<List<FriendGroup>> getUserGroups(String userId) async {
    // Fetch groups the user created
    final createdSnap = await _db
        .collection('groups')
        .where('creatorId', isEqualTo: userId)
        .get();

    // Fetch groups the user is a member of
    final memberSnap = await _db
        .collection('groups')
        .where('memberIds', arrayContains: userId)
        .get();

    // Merge and de-duplicate by id
    final byId = <String, FriendGroup>{};
    for (final doc in createdSnap.docs) {
      final data = doc.data();
      data['id'] = doc.id;
      byId[doc.id] = FriendGroup.fromJson(data);
    }
    for (final doc in memberSnap.docs) {
      final data = doc.data();
      data['id'] = doc.id;
      byId[doc.id] = FriendGroup.fromJson(data);
    }

    final groups = byId.values.toList();
    groups.sort((a, b) => a.name.compareTo(b.name));
    return groups;
  }

  Future<void> addMemberToGroup(String groupId, String userId, String userName) async {
    await _db.collection('groups').doc(groupId).update({
      'memberIds': FieldValue.arrayUnion([userId]),
      'memberNames': FieldValue.arrayUnion([userName]),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> removeMemberFromGroup(String groupId, String userId, String userName) async {
    await _db.collection('groups').doc(groupId).update({
      'memberIds': FieldValue.arrayRemove([userId]),
      'memberNames': FieldValue.arrayRemove([userName]),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }
}
