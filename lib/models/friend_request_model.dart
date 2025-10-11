enum FriendRequestStatus { pending, accepted, rejected }

class FriendRequest {
  final String id;
  final String senderId;
  final String senderName;
  final String? senderPhotoUrl;
  final String receiverId;
  final String receiverName;
  final FriendRequestStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  FriendRequest({
    required this.id,
    required this.senderId,
    required this.senderName,
    this.senderPhotoUrl,
    required this.receiverId,
    required this.receiverName,
    this.status = FriendRequestStatus.pending,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderId': senderId,
    'senderName': senderName,
    'senderPhotoUrl': senderPhotoUrl,
    'receiverId': receiverId,
    'receiverName': receiverName,
    'status': status.toString().split('.').last,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory FriendRequest.fromJson(Map<String, dynamic> json) => FriendRequest(
    id: json['id'] ?? '',
    senderId: json['senderId'] ?? '',
    senderName: json['senderName'] ?? 'Unknown',
    senderPhotoUrl: json['senderPhotoUrl'],
    receiverId: json['receiverId'] ?? '',
    receiverName: json['receiverName'] ?? 'Unknown',
    status: FriendRequestStatus.values.firstWhere(
      (e) => e.toString().split('.').last == json['status'],
      orElse: () => FriendRequestStatus.pending,
    ),
    createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
    updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : DateTime.now(),
  );

  FriendRequest copyWith({
    String? id,
    String? senderId,
    String? senderName,
    String? senderPhotoUrl,
    String? receiverId,
    String? receiverName,
    FriendRequestStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => FriendRequest(
    id: id ?? this.id,
    senderId: senderId ?? this.senderId,
    senderName: senderName ?? this.senderName,
    senderPhotoUrl: senderPhotoUrl ?? this.senderPhotoUrl,
    receiverId: receiverId ?? this.receiverId,
    receiverName: receiverName ?? this.receiverName,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
