import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hoopsight/models/review_model.dart';

class ReviewService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> addReview(Review review) async {
    await _db.collection('reviews').doc(review.id).set(review.toJson());
    await _updateParkRating(review.parkId);
  }

  Future<void> createReview(Review review) async {
    await addReview(review);
  }

  Future<List<Review>> getParkReviews(String parkId) async {
    return await getReviewsByPark(parkId);
  }

  Future<List<Review>> getReviewsByPark(String parkId) async {
    final snapshot = await _db
        .collection('reviews')
        .where('parkId', isEqualTo: parkId)
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Review.fromJson(data);
    }).toList();
  }

  Future<List<Review>> getReviewsByUser(String userId) async {
    final snapshot = await _db
        .collection('reviews')
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      data['id'] = doc.id;
      return Review.fromJson(data);
    }).toList();
  }

  Future<void> deleteReview(String reviewId, String parkId) async {
    await _db.collection('reviews').doc(reviewId).delete();
    await _updateParkRating(parkId);
  }

  Future<void> updateReview(Review review) async {
    await _db.collection('reviews').doc(review.id).update(review.toJson());
  }

  Future<void> _updateParkRating(String parkId) async {
    final reviews = await getReviewsByPark(parkId);
    if (reviews.isEmpty) {
      await _db.collection('parks').doc(parkId).update({
        'averageRating': 0.0,
        'totalReviews': 0,
      });
      return;
    }

    final totalRating = reviews.fold<double>(0, (sum, review) => sum + review.rating);
    final averageRating = totalRating / reviews.length;

    await _db.collection('parks').doc(parkId).update({
      'averageRating': averageRating,
      'totalReviews': reviews.length,
    });
  }
}
