import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hoopsight/models/report_model.dart';

class ReportService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> submitReport(UserReport report) async {
    await _db.collection('reports').doc(report.id).set(report.toJson());
  }

  Future<List<UserReport>> getReportsByReporter(String userId) async {
    final snap = await _db
        .collection('reports')
        .where('reporterId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .get();
    return snap.docs.map((d) {
      final data = d.data();
      data['id'] = d.id;
      return UserReport.fromJson(data);
    }).toList();
  }
}
