import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hoopsight/models/park_model.dart';

class CloudParkService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<List<Park>> getParks() async {
    final snapshot = await _db.collection('parks').orderBy('name').get();
    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Park.fromJson(data);
    }).toList();
  }

  Future<Park?> getPark(String parkId) async {
    final doc = await _db.collection('parks').doc(parkId).get();
    if (doc.exists) {
      final data = doc.data()!;
      data['id'] = doc.id;
      return Park.fromJson(data);
    }
    return null;
  }

  Future<void> addPark(Park park) async {
    await _db.collection('parks').doc(park.id).set(park.toJson());
  }

  Future<void> updatePark(Park park) async {
    await _db.collection('parks').doc(park.id).update(park.toJson());
  }

  Future<void> deletePark(String parkId) async {
    await _db.collection('parks').doc(parkId).delete();
  }

  Stream<List<Park>> watchParks() {
    return _db.collection('parks').orderBy('name').snapshots().map(
      (snapshot) => snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return Park.fromJson(data);
      }).toList(),
    );
  }

  Stream<Park?> watchPark(String parkId) {
    return _db.collection('parks').doc(parkId).snapshots().map(
      (doc) {
        if (doc.exists) {
          final data = doc.data()!;
          data['id'] = doc.id;
          return Park.fromJson(data);
        }
        return null;
      },
    );
  }

  Future<List<Park>> searchParks(String query) async {
    final snapshot = await _db
        .collection('parks')
        .where('name', isGreaterThanOrEqualTo: query)
        .where('name', isLessThanOrEqualTo: '$query\uf8ff')
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Park.fromJson(data);
    }).toList();
  }

  Future<void> joinQueue(String parkId, String courtId, String userId, String userName) async {
    final park = await getPark(parkId);
    if (park == null) return;

    final now = DateTime.now();
    final updatedCourts = park.courts.map((court) {
      if (court.id == courtId) {
        final isAlreadyInQueue = court.gotNextQueue.any((p) => p.userId == userId);
        if (!isAlreadyInQueue) {
          final updatedQueue = [...court.gotNextQueue, QueuePlayer(userId: userId, userName: userName, joinedAt: now, lastActivity: now)];
          return court.copyWith(gotNextQueue: updatedQueue, lastUpdated: now);
        }
      }
      return court;
    }).toList();

    await updatePark(park.copyWith(courts: updatedCourts, updatedAt: now));
  }

  Future<void> leaveQueue(String parkId, String courtId, String userId) async {
    final park = await getPark(parkId);
    if (park == null) return;

    final updatedCourts = park.courts.map((court) {
      if (court.id == courtId) {
        final updatedQueue = court.gotNextQueue.where((p) => p.userId != userId).toList();
        return court.copyWith(gotNextQueue: updatedQueue, lastUpdated: DateTime.now());
      }
      return court;
    }).toList();

    await updatePark(park.copyWith(courts: updatedCourts, updatedAt: DateTime.now()));
  }

  Future<void> addCourt(String parkId, Court court) async {
    final park = await getPark(parkId);
    if (park == null) return;

    final updatedCourts = [...park.courts, court];
    await updatePark(park.copyWith(courts: updatedCourts, updatedAt: DateTime.now()));
  }

  Future<void> removeCourt(String parkId, String courtId) async {
    final park = await getPark(parkId);
    if (park == null) return;

    final updatedCourts = park.courts.where((c) => c.id != courtId).toList();
    await updatePark(park.copyWith(courts: updatedCourts, updatedAt: DateTime.now()));
  }

  Future<void> updateCourt(String parkId, Court updatedCourt) async {
    final park = await getPark(parkId);
    if (park == null) return;

    final updatedCourts = park.courts.map((court) {
      return court.id == updatedCourt.id ? updatedCourt : court;
    }).toList();

    await updatePark(park.copyWith(courts: updatedCourts, updatedAt: DateTime.now()));
  }

  Future<void> updateCourtPlayerCount(String parkId, String courtId, int newPlayerCount) async {
    final park = await getPark(parkId);
    if (park == null) return;

    final updatedCourts = park.courts.map((court) {
      if (court.id == courtId) {
        return court.copyWith(playerCount: newPlayerCount, lastUpdated: DateTime.now());
      }
      return court;
    }).toList();

    await updatePark(park.copyWith(courts: updatedCourts, updatedAt: DateTime.now()));
  }

  Future<void> refreshQueueActivity(String parkId, String courtId, String userId) async {
    final park = await getPark(parkId);
    if (park == null) return;

    final now = DateTime.now();
    final updatedCourts = park.courts.map((court) {
      if (court.id == courtId) {
        final updatedQueue = court.gotNextQueue.map((player) {
          if (player.userId == userId) {
            return QueuePlayer(
              userId: player.userId,
              userName: player.userName,
              joinedAt: player.joinedAt,
              lastActivity: now,
            );
          }
          return player;
        }).toList();
        return court.copyWith(gotNextQueue: updatedQueue, lastUpdated: now);
      }
      return court;
    }).toList();

    await updatePark(park.copyWith(courts: updatedCourts, updatedAt: now));
  }

  Future<void> cleanupExpiredQueuePlayers(String parkId) async {
    final park = await getPark(parkId);
    if (park == null) return;

    final now = DateTime.now();
    bool hasChanges = false;

    final updatedCourts = park.courts.map((court) {
      final activeQueue = court.gotNextQueue.where((player) {
        final timeSinceActivity = now.difference(player.lastActivity ?? player.joinedAt);
        // Keep only entries with activity within last 60 minutes
        return timeSinceActivity.inMinutes < 60;
      }).toList();

      if (activeQueue.length != court.gotNextQueue.length) {
        hasChanges = true;
        return court.copyWith(gotNextQueue: activeQueue, lastUpdated: now);
      }
      return court;
    }).toList();

    if (hasChanges) {
      await updatePark(park.copyWith(courts: updatedCourts, updatedAt: now));
    }
  }
}
