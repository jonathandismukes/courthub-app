import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/services/location_service.dart';

class ParkWithDistance {
  final Park park;
  final double distanceInMiles;

  ParkWithDistance({required this.park, required this.distanceInMiles});
}

class ParkService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final LocationService _locationService = LocationService();

  Future<List<Park>> getParks() async {
    final snapshot = await _db.collection('parks').orderBy('name').get();
    final all = snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Park.fromJson(data);
    }).toList();
    return all.where((p) => p.approved).toList();
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

  Future<void> updateCourtPlayerCount(String parkId, String courtId, int playerCount) async {
    final park = await getPark(parkId);
    if (park != null) {
      final courtIndex = park.courts.indexWhere((c) => c.id == courtId);
      if (courtIndex != -1) {
        final updatedCourt = park.courts[courtIndex].copyWith(
          playerCount: playerCount,
          lastUpdated: DateTime.now(),
        );
        
        final updatedCourts = List<Court>.from(park.courts);
        updatedCourts[courtIndex] = updatedCourt;
        
        final updatedPark = park.copyWith(
          courts: updatedCourts,
          updatedAt: DateTime.now(),
        );
        
        await updatePark(updatedPark);
      }
    }
  }

  Stream<List<Park>> watchParks() {
    return _db.collection('parks').orderBy('name').snapshots().map(
      (snapshot) {
        final all = snapshot.docs.map((doc) {
          final data = doc.data();
          data['id'] = doc.id;
          return Park.fromJson(data);
        }).toList();
        return all.where((p) => p.approved).toList();
      },
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
    final all = snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Park.fromJson(data);
    }).toList();
    return all.where((p) => p.approved).toList();
  }

  Future<List<Park>> searchParksByCity(String city, String state) async {
    final snapshot = await _db
        .collection('parks')
        .where('city', isEqualTo: city)
        .where('state', isEqualTo: state)
        .get();
    final all = snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Park.fromJson(data);
    }).toList();
    return all.where((p) => p.approved).toList();
  }

  Future<List<Park>> getParksByIds(List<String> parkIds) async {
    if (parkIds.isEmpty) return [];
    
    final snapshot = await _db
        .collection('parks')
        .where(FieldPath.documentId, whereIn: parkIds)
        .get();
    final all = snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Park.fromJson(data);
    }).toList();
    return all.where((p) => p.approved).toList();
  }

  // Admin-only helpers
  Future<List<Park>> getPendingParks() async {
    final snap = await _db.collection('parks').where('approved', isEqualTo: false).get();
    final all = snap.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Park.fromJson(data);
    }).toList();
    // Only show items that are still pending review (exclude denied)
    return all.where((p) => p.reviewStatus == 'pending').toList();
  }

  Future<void> approvePark(String parkId, String approverId) async {
    await _db.collection('parks').doc(parkId).update({
      'approved': true,
      'reviewStatus': 'approved',
      'approvedByUserId': approverId,
      'approvedAt': DateTime.now().toIso8601String(),
      'reviewedByUserId': approverId,
      'reviewedAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> denyPark(String parkId, String approverId, String reason) async {
    await _db.collection('parks').doc(parkId).update({
      'approved': false,
      'reviewStatus': 'denied',
      'reviewMessage': reason,
      'reviewedByUserId': approverId,
      'reviewedAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<List<ParkWithDistance>> getNearbyParks(double userLat, double userLon, double radiusMiles) async {
    final allParks = await getParks();
    final parksWithDistance = <ParkWithDistance>[];

    for (final park in allParks) {
      final distance = _locationService.calculateDistance(
        userLat,
        userLon,
        park.latitude,
        park.longitude,
      );

      if (distance <= radiusMiles) {
        parksWithDistance.add(ParkWithDistance(
          park: park,
          distanceInMiles: distance,
        ));
      }
    }

    parksWithDistance.sort((a, b) => a.distanceInMiles.compareTo(b.distanceInMiles));
    return parksWithDistance;
  }
}
