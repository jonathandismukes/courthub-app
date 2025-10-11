
import 'package:flutter/foundation.dart';
import 'package:firebase_storage/firebase_storage.dart';

class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;

  Future<String> uploadParkPhoto(String parkId, Uint8List imageData, String fileName) async {
    try {
      final ref = _storage.ref().child('parks/$parkId/$fileName');
      await ref.putData(imageData);
      return await ref.getDownloadURL();
    } catch (e) {
      debugPrint('Error uploading park photo: $e');
      rethrow;
    }
  }

  Future<String> uploadUserPhoto(String userId, Uint8List imageData) async {
    try {
      final ref = _storage.ref().child('users/$userId/profile.jpg');
      await ref.putData(imageData);
      return await ref.getDownloadURL();
    } catch (e) {
      debugPrint('Error uploading user photo: $e');
      rethrow;
    }
  }

  Future<String> uploadReviewPhoto(String reviewId, Uint8List imageData, String fileName) async {
    try {
      final ref = _storage.ref().child('reviews/$reviewId/$fileName');
      await ref.putData(imageData);
      return await ref.getDownloadURL();
    } catch (e) {
      debugPrint('Error uploading review photo: $e');
      rethrow;
    }
  }

  Future<String> uploadReportEvidence(String reportId, Uint8List imageData, String fileName) async {
    try {
      final ref = _storage.ref().child('reports/$reportId/$fileName');
      await ref.putData(imageData);
      return await ref.getDownloadURL();
    } catch (e) {
      debugPrint('Error uploading report evidence: $e');
      rethrow;
    }
  }

  Future<void> deleteFile(String fileUrl) async {
    try {
      final ref = _storage.refFromURL(fileUrl);
      await ref.delete();
    } catch (e) {
      debugPrint('Error deleting file: $e');
      rethrow;
    }
  }
}
