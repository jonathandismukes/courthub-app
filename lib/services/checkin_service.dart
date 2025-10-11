import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hoopsight/models/checkin_model.dart';
import 'package:hoopsight/services/park_service.dart';

class CheckInService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final ParkService _parkService = ParkService();

  Future<void> checkIn(CheckIn checkIn) async {
    // Create check-in document
    await _db.collection('checkins').doc(checkIn.id).set(checkIn.toJson());
    
    // Increment court player count only if user is actively playing (not just queued)
    if (checkIn.isActive && !(checkIn.inQueue)) {
      await _incrementCourtPlayerCount(checkIn.parkId, checkIn.courtNumber, checkIn.playerCount);
    }
  }

  Future<void> createCheckIn(CheckIn checkIn) async {
    await this.checkIn(checkIn);
  }

  Future<List<CheckIn>> getParkCheckIns(String parkId) async {
    return await getActiveCheckInsByPark(parkId);
  }

  Future<void> checkOut(String checkInId) async {
    // Get check-in details before updating
    final checkInDoc = await _db.collection('checkins').doc(checkInId).get();
    if (checkInDoc.exists) {
      final checkInData = checkInDoc.data()!;
      final parkId = checkInData['parkId'] as String;
      final courtNumber = checkInData['courtNumber'] as int;
      // Safely parse numeric value even if stored as double
      final playerCount = (checkInData['playerCount'] as num?)?.toInt() ?? 1;
      
      // Update check-in to inactive
      await _db.collection('checkins').doc(checkInId).update({
        'checkOutTime': DateTime.now().toIso8601String(),
        'isActive': false,
      });
      
      // Decrement court player count by the number of players that were checked in
      await _decrementCourtPlayerCount(parkId, courtNumber, playerCount);
    }
  }

  Future<CheckIn?> getActiveCheckIn(String userId) async {
    final snapshot = await _db
        .collection('checkins')
        .where('userId', isEqualTo: userId)
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();

    if (snapshot.docs.isNotEmpty) {
      final data = snapshot.docs.first.data();
      data['id'] = snapshot.docs.first.id;
      return CheckIn.fromJson(data);
    }
    return null;
  }

  Future<List<CheckIn>> getActiveCheckInsByPark(String parkId) async {
    final snapshot = await _db
        .collection('checkins')
        .where('parkId', isEqualTo: parkId)
        .where('isActive', isEqualTo: true)
        .orderBy('checkInTime', descending: true)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return CheckIn.fromJson(data);
    }).toList();
  }

  Future<List<CheckIn>> getUserCheckInHistory(String userId) async {
    final snapshot = await _db
        .collection('checkins')
        .where('userId', isEqualTo: userId)
        .orderBy('checkInTime', descending: true)
        .limit(50)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return CheckIn.fromJson(data);
    }).toList();
  }

  Future<void> deleteCheckIn(String checkInId) async {
    // Get check-in details before deleting
    final checkInDoc = await _db.collection('checkins').doc(checkInId).get();
    if (checkInDoc.exists) {
      final checkInData = checkInDoc.data()!;
      final isActive = checkInData['isActive'] as bool? ?? false;
      
      // Only decrement if the check-in was still active
      if (isActive) {
        final parkId = checkInData['parkId'] as String;
        final courtNumber = checkInData['courtNumber'] as int;
        // Safely parse numeric value even if stored as double
        final playerCount = (checkInData['playerCount'] as num?)?.toInt() ?? 1;
        await _decrementCourtPlayerCount(parkId, courtNumber, playerCount);
      }
      
      await _db.collection('checkins').doc(checkInId).delete();
    }
  }

  // Helper: Increment court player count
  Future<void> _incrementCourtPlayerCount(String parkId, int courtNumber, int playersToAdd) async {
    try {
      final park = await _parkService.getPark(parkId);
      if (park != null) {
        final courtIndex = park.courts.indexWhere((c) => c.courtNumber == courtNumber);
        if (courtIndex != -1) {
          final court = park.courts[courtIndex];
          final currentCount = court.playerCount;
          final newCount = currentCount + playersToAdd;
          debugPrint('🏀 Incrementing Court ${courtNumber} player count: $currentCount → $newCount (added $playersToAdd players)');
          await _parkService.updateCourtPlayerCount(parkId, court.id, newCount);
        }
      }
    } catch (e) {
      debugPrint('Error incrementing court player count: $e');
    }
  }

  // Helper: Decrement court player count
  Future<void> _decrementCourtPlayerCount(String parkId, int courtNumber, int playersToRemove) async {
    try {
      final park = await _parkService.getPark(parkId);
      if (park != null) {
        final courtIndex = park.courts.indexWhere((c) => c.courtNumber == courtNumber);
        if (courtIndex != -1) {
          final court = park.courts[courtIndex];
          final currentCount = court.playerCount;
          // Don't go below 0
          final newCount = (currentCount - playersToRemove).clamp(0, double.infinity).toInt();
          debugPrint('🏀 Decrementing Court ${courtNumber} player count: $currentCount → $newCount (removed $playersToRemove players)');
          await _parkService.updateCourtPlayerCount(parkId, court.id, newCount);
        }
      }
    } catch (e) {
      debugPrint('Error decrementing court player count: $e');
    }
  }
}
