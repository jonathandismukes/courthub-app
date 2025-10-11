class AppUser {
  final String id;
  final String email;
  final String displayName;
  final String? photoUrl;
  final String? bio;
  final String? phoneNumber;
  final List<String> favoriteParkIds;
  final Map<String, bool> favoriteNotifications;
  final Map<String, bool> groupNotifications;
  final List<String> friendIds;
  // Users that this user has blocked. Mutually respected across app interactions.
  final List<String> blockedUserIds;
  final int gamesPlayed;
  final String skillLevel;
  final bool isAdmin;
  final DateTime createdAt;
  final DateTime updatedAt;

  AppUser({
    required this.id,
    required this.email,
    required this.displayName,
    this.photoUrl,
    this.bio,
    this.phoneNumber,
    this.favoriteParkIds = const [],
    this.favoriteNotifications = const {},
    this.groupNotifications = const {},
    this.friendIds = const [],
    this.blockedUserIds = const [],
    this.gamesPlayed = 0,
    this.skillLevel = 'Intermediate',
    this.isAdmin = false,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'displayName': displayName,
    'photoUrl': photoUrl,
    'bio': bio,
    'phoneNumber': phoneNumber,
    'favoriteParkIds': favoriteParkIds,
    'favoriteNotifications': favoriteNotifications,
    'groupNotifications': groupNotifications,
    'friendIds': friendIds,
    'blockedUserIds': blockedUserIds,
    'gamesPlayed': gamesPlayed,
    'skillLevel': skillLevel,
    'isAdmin': isAdmin,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] ?? '',
    email: json['email'] ?? '',
    displayName: json['displayName'] ?? 'Unknown User',
    photoUrl: json['photoUrl'],
    bio: json['bio'],
    phoneNumber: json['phoneNumber'],
    favoriteParkIds: List<String>.from(json['favoriteParkIds'] ?? []),
    favoriteNotifications: Map<String, bool>.from(json['favoriteNotifications'] ?? {}),
    groupNotifications: Map<String, bool>.from(json['groupNotifications'] ?? {}),
    friendIds: List<String>.from(json['friendIds'] ?? []),
    blockedUserIds: List<String>.from(json['blockedUserIds'] ?? []),
    gamesPlayed: json['gamesPlayed'] ?? 0,
    skillLevel: json['skillLevel'] ?? 'Intermediate',
    isAdmin: json['isAdmin'] ?? false,
    createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
    updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : DateTime.now(),
  );

  AppUser copyWith({
    String? id,
    String? email,
    String? displayName,
    String? photoUrl,
    String? bio,
    String? phoneNumber,
    List<String>? favoriteParkIds,
    Map<String, bool>? favoriteNotifications,
    Map<String, bool>? groupNotifications,
    List<String>? friendIds,
    List<String>? blockedUserIds,
    int? gamesPlayed,
    String? skillLevel,
    bool? isAdmin,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => AppUser(
    id: id ?? this.id,
    email: email ?? this.email,
    displayName: displayName ?? this.displayName,
    photoUrl: photoUrl ?? this.photoUrl,
    bio: bio ?? this.bio,
    phoneNumber: phoneNumber ?? this.phoneNumber,
    favoriteParkIds: favoriteParkIds ?? this.favoriteParkIds,
    favoriteNotifications: favoriteNotifications ?? this.favoriteNotifications,
    groupNotifications: groupNotifications ?? this.groupNotifications,
    friendIds: friendIds ?? this.friendIds,
    blockedUserIds: blockedUserIds ?? this.blockedUserIds,
    gamesPlayed: gamesPlayed ?? this.gamesPlayed,
    skillLevel: skillLevel ?? this.skillLevel,
    isAdmin: isAdmin ?? this.isAdmin,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
