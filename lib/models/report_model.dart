enum ReportTargetType { profile, review, message }

class UserReport {
  final String id;
  final String reporterId;
  final String reporterName;
  final String targetId; // userId, reviewId, or messageId
  final ReportTargetType targetType;
  final String reason; // selected reason label
  final String? notes;
  final String? screenshotUrl;
  final DateTime createdAt;
  final String status; // open, reviewed, action_taken

  const UserReport({
    required this.id,
    required this.reporterId,
    required this.reporterName,
    required this.targetId,
    required this.targetType,
    required this.reason,
    this.notes,
    this.screenshotUrl,
    required this.createdAt,
    this.status = 'open',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'reporterId': reporterId,
        'reporterName': reporterName,
        'targetId': targetId,
        'targetType': targetType.toString().split('.').last,
        'reason': reason,
        'notes': notes,
        'screenshotUrl': screenshotUrl,
        'createdAt': createdAt.toIso8601String(),
        'status': status,
      };

  factory UserReport.fromJson(Map<String, dynamic> json) => UserReport(
        id: json['id'] ?? '',
        reporterId: json['reporterId'] ?? '',
        reporterName: json['reporterName'] ?? 'Anonymous',
        targetId: json['targetId'] ?? '',
        targetType: ReportTargetType.values.firstWhere(
          (e) => e.toString().split('.').last == json['targetType'],
          orElse: () => ReportTargetType.profile,
        ),
        reason: json['reason'] ?? '',
        notes: json['notes'],
        screenshotUrl: json['screenshotUrl'],
        createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
        status: json['status'] ?? 'open',
      );
}
