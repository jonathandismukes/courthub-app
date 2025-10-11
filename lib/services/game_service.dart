import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hoopsight/models/game_model.dart';

class GameService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> createGame(Game game) async {
    await _db.collection('games').doc(game.id).set(game.toJson());
  }

  Future<void> updateGame(Game game) async {
    await _db.collection('games').doc(game.id).update(game.toJson());
  }

  Future<Game?> getGame(String gameId) async {
    final doc = await _db.collection('games').doc(gameId).get();
    if (doc.exists) {
      final data = doc.data()!;
      data['id'] = doc.id;
      return Game.fromJson(data);
    }
    return null;
  }

  Future<List<Game>> getGamesByPark(String parkId) async {
    // Fetch by park only, then filter by status and sort client-side to avoid composite index requirements.
    final snapshot = await _db
        .collection('games')
        .where('parkId', isEqualTo: parkId)
        .get();

    final games = snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Game.fromJson(data);
    }).toList();

    final filtered = games
        .where((g) => g.status == GameStatus.scheduled || g.status == GameStatus.active)
        .toList();
    filtered.sort((a, b) => a.scheduledTime.compareTo(b.scheduledTime));
    return filtered;
  }

  Future<List<Game>> getUpcomingGames() async {
    final now = DateTime.now();
    final snapshot = await _db
        .collection('games')
        .where('scheduledTime', isGreaterThan: now.toIso8601String())
        .where('status', isEqualTo: 'scheduled')
        .orderBy('scheduledTime')
        .limit(20)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Game.fromJson(data);
    }).toList();
  }

  Future<List<Game>> getUserGames(String userId) async {
    // Avoid requiring a composite index by not ordering on the server.
    // We'll sort by scheduledTime on the client after fetching.
    final snapshot = await _db
        .collection('games')
        .where('playerIds', arrayContains: userId)
        .get();

    final games = snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Game.fromJson(data);
    }).toList();

    // Sort newest scheduledTime first
    games.sort((a, b) => b.scheduledTime.compareTo(a.scheduledTime));
    return games;
  }

  Future<void> joinGame(String gameId, String userId, String userName) async {
    final game = await getGame(gameId);
    if (game != null && game.playerIds.length < game.maxPlayers) {
      await _db.collection('games').doc(gameId).update({
        'playerIds': FieldValue.arrayUnion([userId]),
        'playerNames': FieldValue.arrayUnion([userName]),
      });
    }
  }

  Future<void> leaveGame(String gameId, String userId, String userName) async {
    await _db.collection('games').doc(gameId).update({
      'playerIds': FieldValue.arrayRemove([userId]),
      'playerNames': FieldValue.arrayRemove([userName]),
    });
  }

  Future<void> cancelGame(String gameId) async {
    await _db.collection('games').doc(gameId).update({
      'status': 'cancelled',
    });
  }

  Future<void> deleteGame(String gameId) async {
    await _db.collection('games').doc(gameId).delete();
  }
}
