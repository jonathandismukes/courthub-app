class Review {
  final String id;
  final String parkId;
  final String userId;
  final String userName;
  final String? userPhotoUrl;
  final double rating;
  final String comment;
  final List<String> photoUrls;
  final DateTime createdAt;
  final DateTime updatedAt;

  Review({
    required this.id,
    required this.parkId,
    required this.userId,
    required this.userName,
    this.userPhotoUrl,
    required this.rating,
    required this.comment,
    this.photoUrls = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'parkId': parkId,
    'userId': userId,
    'userName': userName,
    'userPhotoUrl': userPhotoUrl,
    'rating': rating,
    'comment': comment,
    'photoUrls': photoUrls,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Review.fromJson(Map<String, dynamic> json) => Review(
    id: json['id'] ?? '',
    parkId: json['parkId'] ?? '',
    userId: json['userId'] ?? '',
    userName: json['userName'] ?? 'Anonymous',
    userPhotoUrl: json['userPhotoUrl'],
    rating: (json['rating'] ?? 0.0).toDouble(),
    comment: json['comment'] ?? '',
    photoUrls: List<String>.from(json['photoUrls'] ?? []),
    createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
    updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : DateTime.now(),
  );
}
