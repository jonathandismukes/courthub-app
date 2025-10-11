class CheckIn {
  final String id;
  final String userId;
  final String userName;
  final String? userPhotoUrl;
  final String parkId;
  final String parkName;
  final int courtNumber;
  final int playerCount;
  final bool? preferDoubles;
  final String? notes;
  final DateTime checkInTime;
  final DateTime? checkOutTime;
  final bool isActive;
  final bool inQueue;
  final DateTime createdAt;
  final DateTime updatedAt;

  CheckIn({
    required this.id,
    required this.userId,
    required this.userName,
    this.userPhotoUrl,
    required this.parkId,
    required this.parkName,
    required this.courtNumber,
    required this.playerCount,
    this.preferDoubles,
    this.notes,
    required this.checkInTime,
    this.checkOutTime,
    this.isActive = true,
    this.inQueue = true,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'userId': userId,
    'userName': userName,
    'userPhotoUrl': userPhotoUrl,
    'parkId': parkId,
    'parkName': parkName,
    'courtNumber': courtNumber,
    'playerCount': playerCount,
    'preferDoubles': preferDoubles,
    'notes': notes,
    'checkInTime': checkInTime.toIso8601String(),
    'checkOutTime': checkOutTime?.toIso8601String(),
    'isActive': isActive,
    'inQueue': inQueue,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory CheckIn.fromJson(Map<String, dynamic> json) => CheckIn(
    id: json['id'] ?? '',
    userId: json['userId'] ?? '',
    userName: json['userName'] ?? 'Anonymous',
    userPhotoUrl: json['userPhotoUrl'],
    parkId: json['parkId'] ?? '',
    parkName: json['parkName'] ?? '',
    courtNumber: json['courtNumber'] ?? 1,
    playerCount: json['playerCount'] ?? 0,
    preferDoubles: json['preferDoubles'],
    notes: json['notes'],
    checkInTime: json['checkInTime'] != null ? DateTime.parse(json['checkInTime']) : DateTime.now(),
    checkOutTime: json['checkOutTime'] != null ? DateTime.parse(json['checkOutTime']) : null,
    isActive: json['isActive'] ?? true,
    inQueue: json['inQueue'] ?? true,
    createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
    updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : DateTime.now(),
  );

  CheckIn copyWith({
    String? id,
    String? userId,
    String? userName,
    String? userPhotoUrl,
    String? parkId,
    String? parkName,
    int? courtNumber,
    int? playerCount,
    bool? preferDoubles,
    String? notes,
    DateTime? checkInTime,
    DateTime? checkOutTime,
    bool? isActive,
    bool? inQueue,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => CheckIn(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    userName: userName ?? this.userName,
    userPhotoUrl: userPhotoUrl ?? this.userPhotoUrl,
    parkId: parkId ?? this.parkId,
    parkName: parkName ?? this.parkName,
    courtNumber: courtNumber ?? this.courtNumber,
    playerCount: playerCount ?? this.playerCount,
    preferDoubles: preferDoubles ?? this.preferDoubles,
    notes: notes ?? this.notes,
    checkInTime: checkInTime ?? this.checkInTime,
    checkOutTime: checkOutTime ?? this.checkOutTime,
    isActive: isActive ?? this.isActive,
    inQueue: inQueue ?? this.inQueue,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
