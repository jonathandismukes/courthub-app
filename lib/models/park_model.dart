class Park {
  final String id;
  final String name;
  final String address;
  final String city;
  final String state;
  final double latitude;
  final double longitude;
  final List<Court> courts;
  final List<String> photoUrls;
  final List<String> amenities;
  final double averageRating;
  final int totalReviews;
  final String? description;
  // Moderation fields
  final bool approved; // If false, hidden from non-admin users until approval
  // Moderation review status: 'pending' | 'approved' | 'denied'
  final String reviewStatus;
  final String? reviewMessage; // optional message when denied
  final String? createdByUserId;
  final String? createdByName;
  final String? approvedByUserId;
  final DateTime? approvedAt;
  final String? reviewedByUserId; // approver/denier
  final DateTime? reviewedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  Park({
    required this.id,
    required this.name,
    required this.address,
    required this.city,
    required this.state,
    required this.latitude,
    required this.longitude,
    required this.courts,
    this.photoUrls = const [],
    this.amenities = const [],
    this.averageRating = 0.0,
    this.totalReviews = 0,
    this.description,
    this.approved = true,
    this.reviewStatus = 'approved',
    this.reviewMessage,
    this.createdByUserId,
    this.createdByName,
    this.approvedByUserId,
    this.approvedAt,
    this.reviewedByUserId,
    this.reviewedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'city': city,
    'state': state,
    'latitude': latitude,
    'longitude': longitude,
    'courts': courts.map((c) => c.toJson()).toList(),
    'photoUrls': photoUrls,
    'amenities': amenities,
    'averageRating': averageRating,
    'totalReviews': totalReviews,
    'description': description,
    'approved': approved,
    'reviewStatus': reviewStatus,
    'reviewMessage': reviewMessage,
    'createdByUserId': createdByUserId,
    'createdByName': createdByName,
    'approvedByUserId': approvedByUserId,
    'approvedAt': approvedAt?.toIso8601String(),
    'reviewedByUserId': reviewedByUserId,
    'reviewedAt': reviewedAt?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Park.fromJson(Map<String, dynamic> json) => Park(
    id: json['id'] ?? '',
    name: json['name'] ?? 'Unknown Park',
    address: json['address'] ?? 'Address not specified',
    city: json['city'] ?? '',
    state: json['state'] ?? '',
    latitude: (json['latitude'] ?? 0.0).toDouble(),
    longitude: (json['longitude'] ?? 0.0).toDouble(),
    courts: (json['courts'] as List? ?? []).map((c) => Court.fromJson(c)).toList(),
    photoUrls: List<String>.from(json['photoUrls'] ?? []),
    amenities: List<String>.from(json['amenities'] ?? []),
    averageRating: (json['averageRating'] ?? 0.0).toDouble(),
    totalReviews: json['totalReviews'] ?? 0,
    description: json['description'],
    approved: json['approved'] is bool ? (json['approved'] as bool) : true,
    reviewStatus: (json['reviewStatus'] as String?) ?? ((json['approved'] is bool ? (json['approved'] as bool) : true) ? 'approved' : 'pending'),
    reviewMessage: json['reviewMessage'] as String?,
    createdByUserId: json['createdByUserId'],
    createdByName: json['createdByName'],
    approvedByUserId: json['approvedByUserId'],
    approvedAt: json['approvedAt'] != null ? DateTime.parse(json['approvedAt']) : null,
    reviewedByUserId: json['reviewedByUserId'] as String?,
    reviewedAt: json['reviewedAt'] != null ? DateTime.parse(json['reviewedAt']) : null,
    createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
    updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : DateTime.now(),
  );

  Park copyWith({
    String? id,
    String? name,
    String? address,
    String? city,
    String? state,
    double? latitude,
    double? longitude,
    List<Court>? courts,
    List<String>? photoUrls,
    List<String>? amenities,
    double? averageRating,
    int? totalReviews,
    String? description,
    bool? approved,
    String? reviewStatus,
    String? reviewMessage,
    String? createdByUserId,
    String? createdByName,
    String? approvedByUserId,
    DateTime? approvedAt,
    String? reviewedByUserId,
    DateTime? reviewedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Park(
    id: id ?? this.id,
    name: name ?? this.name,
    address: address ?? this.address,
    city: city ?? this.city,
    state: state ?? this.state,
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    courts: courts ?? this.courts,
    photoUrls: photoUrls ?? this.photoUrls,
    amenities: amenities ?? this.amenities,
    averageRating: averageRating ?? this.averageRating,
    totalReviews: totalReviews ?? this.totalReviews,
    description: description ?? this.description,
    approved: approved ?? this.approved,
    reviewStatus: reviewStatus ?? this.reviewStatus,
    reviewMessage: reviewMessage ?? this.reviewMessage,
    createdByUserId: createdByUserId ?? this.createdByUserId,
    createdByName: createdByName ?? this.createdByName,
    approvedByUserId: approvedByUserId ?? this.approvedByUserId,
    approvedAt: approvedAt ?? this.approvedAt,
    reviewedByUserId: reviewedByUserId ?? this.reviewedByUserId,
    reviewedAt: reviewedAt ?? this.reviewedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

enum SportType { basketball, pickleballSingles, pickleballDoubles, tennisSingles, tennisDoubles }

int getMaxPlayersForSport(SportType sport) {
  switch (sport) {
    case SportType.basketball:
      return 10;
    case SportType.pickleballSingles:
    case SportType.pickleballDoubles:
    case SportType.tennisSingles:
    case SportType.tennisDoubles:
      return 4;
  }
}

enum CourtType { fullCourt, halfCourt, threeVthree, pickleballSingles, pickleballDoubles, tennisSingles, tennisDoubles }
enum CourtCondition { excellent, good, fair, poor, maintenance }

class QueuePlayer {
  final String userId;
  final String userName;
  final DateTime joinedAt;
  final DateTime? lastActivity;

  QueuePlayer({
    required this.userId,
    required this.userName,
    required this.joinedAt,
    this.lastActivity,
  });

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'userName': userName,
    'joinedAt': joinedAt.toIso8601String(),
    'lastActivity': lastActivity?.toIso8601String(),
  };

  factory QueuePlayer.fromJson(Map<String, dynamic> json) => QueuePlayer(
    userId: json['userId'] ?? '',
    userName: json['userName'] ?? 'Unknown',
    joinedAt: json['joinedAt'] != null ? DateTime.parse(json['joinedAt']) : DateTime.now(),
    lastActivity: json['lastActivity'] != null ? DateTime.parse(json['lastActivity']) : null,
  );

  Duration get timeInQueue => DateTime.now().difference(lastActivity ?? joinedAt);
  // A queue entry expires if no activity for 60 minutes
  bool get isExpired => timeInQueue.inMinutes >= 60;
}

class Court {
  final String id;
  final int courtNumber;
  final String? customName;
  final int playerCount;
  final SportType sportType;
  final CourtType type;
  final CourtCondition condition;
  final bool hasLighting;
  final bool isHalfCourt;
  final DateTime lastUpdated;
  final String? conditionNotes;
  final List<QueuePlayer> gotNextQueue;

  Court({
    required this.id,
    required this.courtNumber,
    this.customName,
    required this.playerCount,
    this.sportType = SportType.basketball,
    this.type = CourtType.fullCourt,
    this.condition = CourtCondition.good,
    this.hasLighting = false,
    this.isHalfCourt = false,
    required this.lastUpdated,
    this.conditionNotes,
    this.gotNextQueue = const [],
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'courtNumber': courtNumber,
    'customName': customName,
    'playerCount': playerCount,
    'sportType': sportType.toString().split('.').last,
    'type': type.toString().split('.').last,
    'condition': condition.toString().split('.').last,
    'hasLighting': hasLighting,
    'isHalfCourt': isHalfCourt,
    'lastUpdated': lastUpdated.toIso8601String(),
    'conditionNotes': conditionNotes,
    'gotNextQueue': gotNextQueue.map((q) => q.toJson()).toList(),
  };

  factory Court.fromJson(Map<String, dynamic> json) => Court(
    id: json['id'] ?? '',
    courtNumber: json['courtNumber'] ?? 1,
    customName: json['customName'],
    playerCount: json['playerCount'] ?? 0,
    sportType: SportType.values.firstWhere(
      (e) => e.toString().split('.').last == json['sportType'],
      orElse: () => SportType.basketball,
    ),
    type: CourtType.values.firstWhere(
      (e) => e.toString().split('.').last == json['type'],
      orElse: () => CourtType.fullCourt,
    ),
    condition: CourtCondition.values.firstWhere(
      (e) => e.toString().split('.').last == json['condition'],
      orElse: () => CourtCondition.good,
    ),
    hasLighting: json['hasLighting'] ?? false,
    isHalfCourt: json['isHalfCourt'] ?? false,
    lastUpdated: json['lastUpdated'] != null ? DateTime.parse(json['lastUpdated']) : DateTime.now(),
    conditionNotes: json['conditionNotes'],
    gotNextQueue: (json['gotNextQueue'] as List? ?? []).map((q) => QueuePlayer.fromJson(q)).toList(),
  );

  Court copyWith({
    String? id,
    int? courtNumber,
    String? customName,
    int? playerCount,
    SportType? sportType,
    CourtType? type,
    CourtCondition? condition,
    bool? hasLighting,
    bool? isHalfCourt,
    DateTime? lastUpdated,
    String? conditionNotes,
    List<QueuePlayer>? gotNextQueue,
  }) => Court(
    id: id ?? this.id,
    courtNumber: courtNumber ?? this.courtNumber,
    customName: customName ?? this.customName,
    playerCount: playerCount ?? this.playerCount,
    sportType: sportType ?? this.sportType,
    type: type ?? this.type,
    condition: condition ?? this.condition,
    hasLighting: hasLighting ?? this.hasLighting,
    isHalfCourt: isHalfCourt ?? this.isHalfCourt,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    conditionNotes: conditionNotes ?? this.conditionNotes,
    gotNextQueue: gotNextQueue ?? this.gotNextQueue,
  );

  String get displayName => customName ?? 'Court $courtNumber';

  int get maxPlayers => isHalfCourt ? 5 : getMaxPlayersForSport(sportType);
}
