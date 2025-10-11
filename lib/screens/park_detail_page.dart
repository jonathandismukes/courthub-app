import 'package:flutter/material.dart';
import 'dart:async';

import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/models/review_model.dart';
import 'package:hoopsight/models/game_model.dart';
import 'package:hoopsight/models/checkin_model.dart';
import 'package:hoopsight/services/cloud_park_service.dart';
import 'package:hoopsight/services/review_service.dart';
import 'package:hoopsight/services/game_service.dart';
import 'package:hoopsight/services/checkin_service.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/storage_service.dart';
import 'package:hoopsight/services/notification_service.dart';
import 'package:hoopsight/screens/game_detail_page.dart';
import 'package:hoopsight/widgets/court_flip_card.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hoopsight/utils/moderation.dart';
import 'package:hoopsight/services/report_service.dart';
import 'package:hoopsight/models/report_model.dart';
import 'package:hoopsight/screens/qr_scanner_page.dart';
import 'package:intl/intl.dart';

class ParkDetailPage extends StatefulWidget {
  final Park park;

  const ParkDetailPage({super.key, required this.park});

  @override
  State<ParkDetailPage> createState() => _ParkDetailPageState();
}

class _ParkDetailPageState extends State<ParkDetailPage> with SingleTickerProviderStateMixin {
  late Park _park;
  final CloudParkService _parkService = CloudParkService();
  final ReviewService _reviewService = ReviewService();
  final GameService _gameService = GameService();
  final CheckInService _checkInService = CheckInService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final StorageService _storageService = StorageService();
  final NotificationService _notificationService = NotificationService();
  final ReportService _reportService = ReportService();
  
  late TabController _tabController;
  List<Review> _reviews = [];
  List<Game> _games = [];
  List<CheckIn> _checkIns = [];
  CheckIn? _activeCheckIn;
  bool _isFavorite = false;
  bool _favoriteNotificationEnabled = false;
  bool _isLoading = true;
  bool _isUploadingPhoto = false;
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _park = widget.park;
    _tabController = TabController(length: 4, vsync: this);
    _loadData();
  }

  Future<void> _showReportDialogForReview(Review review) async {
    final reasons = ['Inappropriate messages', 'Offensive content', 'Spam', 'Other'];
    String selectedReason = reasons.first;
    final notesController = TextEditingController();
    PlatformFile? pickedFile;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Report Review'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: selectedReason,
                items: reasons.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
                onChanged: (v) => setDialogState(() => selectedReason = v ?? reasons.first),
                decoration: const InputDecoration(labelText: 'Reason'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesController,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
                    if (result != null && result.files.isNotEmpty) {
                      setDialogState(() => pickedFile = result.files.first);
                    }
                  },
                  icon: const Icon(Icons.upload_file),
                  label: Text(pickedFile == null ? 'Upload screenshot' : pickedFile!.name),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final user = _authService.currentUser;
                if (user == null) return;
                String? screenshotUrl;
                final reportId = 'report_${DateTime.now().millisecondsSinceEpoch}';
                if (pickedFile?.bytes != null) {
                  screenshotUrl = await _storageService.uploadReportEvidence(reportId, pickedFile!.bytes!, pickedFile!.name);
                }
                final reporter = await _userService.getUser(user.uid);
                final report = UserReport(
                  id: reportId,
                  reporterId: user.uid,
                  reporterName: reporter?.displayName ?? 'Unknown',
                  targetId: review.id,
                  targetType: ReportTargetType.review,
                  reason: selectedReason,
                  notes: notesController.text.trim().isEmpty ? null : notesController.text.trim(),
                  screenshotUrl: screenshotUrl,
                  createdAt: DateTime.now(),
                );
                await _reportService.submitReport(report);
                if (mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report submitted')));
                }
              },
              child: const Text('Submit'),
            )
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    debugPrint('ParkDetailPage: _loadData start for park ${_park.id}');
    // Prune any stale queue entries (> 60 minutes inactive) before loading
    try {
      await _parkService.cleanupExpiredQueuePlayers(_park.id);
      debugPrint('ParkDetailPage: cleanupExpiredQueuePlayers done');
      final refreshed = await _parkService.getPark(_park.id);
      if (refreshed != null) {
        _park = refreshed;
        debugPrint('ParkDetailPage: park refreshed with ${_park.courts.length} courts');
      }
    } catch (e, st) {
      debugPrint('ParkDetailPage: cleanup/getPark failed: $e\n$st');
    }

    try {
      await Future.wait([
        _loadReviews().then((_) => debugPrint('ParkDetailPage: _loadReviews done')),
        _loadGames().then((_) => debugPrint('ParkDetailPage: _loadGames done')),
        _loadCheckIns().then((_) => debugPrint('ParkDetailPage: _loadCheckIns done')),
        _loadFavoriteStatus().then((_) => debugPrint('ParkDetailPage: _loadFavoriteStatus done')),
        _loadActiveCheckIn().then((_) => debugPrint('ParkDetailPage: _loadActiveCheckIn done')),
      ]).timeout(const Duration(seconds: 10));
      debugPrint('ParkDetailPage: all loads completed');
    } on TimeoutException catch (_) {
      debugPrint('ParkDetailPage: load timeout after 10s — showing partial data');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Loading is slow. Showing partial data.')),
        );
      }
    } catch (e, st) {
      debugPrint('ParkDetailPage: data load failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Some park details failed to load. Showing what we have.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        debugPrint('ParkDetailPage: _isLoading set to false');
      }
    }
  }

  Future<void> _loadReviews() async {
    final reviews = await _reviewService.getParkReviews(_park.id);
    setState(() => _reviews = reviews);
  }

  Future<void> _loadGames() async {
    final games = await _gameService.getGamesByPark(_park.id);
    setState(() => _games = games.where((g) => g.status != GameStatus.completed && g.status != GameStatus.cancelled).toList());
  }

  Future<void> _loadCheckIns() async {
    final checkIns = await _checkInService.getParkCheckIns(_park.id);
    setState(() => _checkIns = checkIns);
  }

  Future<void> _loadFavoriteStatus() async {
    final user = _authService.currentUser;
    if (user != null) {
      final appUser = await _userService.getUser(user.uid);
      if (appUser != null) {
        setState(() {
          _isFavorite = appUser.favoriteParkIds.contains(_park.id);
          _favoriteNotificationEnabled = appUser.favoriteNotifications[_park.id] ?? false;
          _isAdmin = appUser.isAdmin;
        });
      }
    }
  }

  Future<void> _loadActiveCheckIn() async {
    final user = _authService.currentUser;
    if (user != null) {
      final checkIn = await _checkInService.getActiveCheckIn(user.uid);
      if (checkIn != null && checkIn.parkId == _park.id) {
        setState(() => _activeCheckIn = checkIn);
      } else {
        setState(() => _activeCheckIn = null);
      }
    }
  }

  Future<void> _toggleFavorite() async {
    final user = _authService.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to save favorites')),
      );
      return;
    }

    final appUser = await _userService.getUser(user.uid);
    if (appUser != null) {
      if (_isFavorite) {
        await _userService.removeFavoritePark(user.uid, _park.id);
        setState(() {
          _isFavorite = false;
          _favoriteNotificationEnabled = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Removed from favorites')),
        );
      } else {
        await _userService.addFavoritePark(user.uid, _park.id);
        setState(() => _isFavorite = true);
        await _showNotificationSettings();
      }
    }
  }

  Future<void> _showNotificationSettings() async {
    final enable = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Get Notified?'),
        content: const Text('Would you like to receive push notifications when someone checks into this park?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No Thanks'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Enable Notifications'),
          ),
        ],
      ),
    );

    if (enable == true) {
      final user = _authService.currentUser;
      if (user != null) {
          await _userService.toggleFavoriteNotification(user.uid, _park.id, true);
          await _notificationService.ensureAndSaveFCMToken(user.uid);
        setState(() => _favoriteNotificationEnabled = true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Added to favorites with notifications enabled')),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Added to favorites')),
        );
      }
    }
  }

  Future<void> _toggleNotifications() async {
    final user = _authService.currentUser;
    if (user == null) return;

    final newValue = !_favoriteNotificationEnabled;
    await _userService.toggleFavoriteNotification(user.uid, _park.id, newValue);
    
    if (newValue) {
      await _notificationService.ensureAndSaveFCMToken(user.uid);
    }

    setState(() => _favoriteNotificationEnabled = newValue);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(newValue ? 'Notifications enabled' : 'Notifications disabled')),
    );
  }

  Future<void> _uploadPhoto() async {
    final user = _authService.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to upload photos')),
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() => _isUploadingPhoto = true);
      try {
        final file = result.files.first;
        final photoUrl = await _storageService.uploadParkPhoto(_park.id, file.bytes!, file.name);
        
        final updatedPark = _park.copyWith(
          photoUrls: [..._park.photoUrls, photoUrl],
          updatedAt: DateTime.now(),
        );
        
        await _parkService.updatePark(updatedPark);
        setState(() => _park = updatedPark);
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo uploaded successfully')),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      } finally {
        setState(() => _isUploadingPhoto = false);
      }
    }
  }

  Future<void> _showAddCourtDialog() async {
    SportType selectedSportType = SportType.basketball;
    CourtCondition selectedCondition = CourtCondition.good;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add New Court'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<SportType>(
                value: selectedSportType,
                decoration: const InputDecoration(
                  labelText: 'Sport Type',
                  border: OutlineInputBorder(),
                ),
                items: SportType.values.map((sport) {
                  String label;
                  Widget icon;
                  switch (sport) {
                    case SportType.basketball:
                      label = 'Basketball';
                      icon = const Text('🏀 ', style: TextStyle(fontSize: 16));
                      break;
                    case SportType.pickleballSingles:
                      label = 'Pickleball (Singles)';
                      icon = Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: Image.asset('assets/images/p.jpeg', width: 16, height: 16, fit: BoxFit.contain),
                        ),
                      );
                      break;
                    case SportType.pickleballDoubles:
                      label = 'Pickleball (Doubles)';
                      icon = Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: Image.asset('assets/images/p.jpeg', width: 16, height: 16, fit: BoxFit.contain),
                        ),
                      );
                      break;
                    case SportType.tennisSingles:
                      label = 'Tennis (Singles)';
                      icon = const Text('🎾 ', style: TextStyle(fontSize: 16));
                      break;
                    case SportType.tennisDoubles:
                      label = 'Tennis (Doubles)';
                      icon = const Text('🎾 ', style: TextStyle(fontSize: 16));
                      break;
                  }
                  return DropdownMenuItem(
                    value: sport,
                    child: Row(
                      children: [icon, Text(label)],
                    ),
                  );
                }).toList(),
                onChanged: (value) => setDialogState(() => selectedSportType = value!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<CourtCondition>(
                value: selectedCondition,
                decoration: const InputDecoration(
                  labelText: 'Court Condition',
                  border: OutlineInputBorder(),
                ),
                items: CourtCondition.values.map((condition) {
                  String label;
                  switch (condition) {
                    case CourtCondition.excellent:
                      label = 'Excellent';
                      break;
                    case CourtCondition.good:
                      label = 'Good';
                      break;
                    case CourtCondition.fair:
                      label = 'Fair';
                      break;
                    case CourtCondition.poor:
                      label = 'Poor';
                      break;
                    case CourtCondition.maintenance:
                      label = 'Maintenance';
                      break;
                  }
                  return DropdownMenuItem(
                    value: condition,
                    child: Text(label),
                  );
                }).toList(),
                onChanged: (value) => setDialogState(() => selectedCondition = value!),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newCourtNumber = _park.courts.isEmpty ? 1 : _park.courts.map((c) => c.courtNumber).reduce((a, b) => a > b ? a : b) + 1;
              final newCourt = Court(
                id: '${_park.id}_court_$newCourtNumber',
                courtNumber: newCourtNumber,
                sportType: selectedSportType,
                playerCount: 0,
                condition: selectedCondition,
                lastUpdated: DateTime.now(),
                gotNextQueue: [],
              );

              try {
                await _parkService.addCourt(_park.id, newCourt);
                final updatedPark = await _parkService.getPark(_park.id);
                if (updatedPark != null) {
                  setState(() => _park = updatedPark);
                }
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Court added successfully!')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to add court: $e')),
                );
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditCourtDialog(Court court) async {
    String customName = court.customName ?? '';
    bool isHalfCourt = court.isHalfCourt;
    int playerCount = court.playerCount;
    CourtCondition selectedCondition = court.condition;
    
    final customNameController = TextEditingController(text: customName);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit ${court.displayName}'),
        content: StatefulBuilder(
          builder: (context, setDialogState) {
            final maxPlayers = isHalfCourt ? 5 : getMaxPlayersForSport(court.sportType);
            final isBasketball = court.sportType == SportType.basketball;
            
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: customNameController,
                    decoration: const InputDecoration(
                      labelText: 'Custom Name (Optional)',
                      hintText: 'e.g., Main Court, North Court',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: Text('Half Court'),
                    subtitle: Text(isHalfCourt ? 'Max 5 players' : 'Max ${getMaxPlayersForSport(court.sportType)} players'),
                    value: isHalfCourt,
                    onChanged: (value) {
                      setDialogState(() {
                        isHalfCourt = value;
                        // Adjust player count if it exceeds new max
                        final newMaxPlayers = isHalfCourt ? 5 : getMaxPlayersForSport(court.sportType);
                        if (playerCount > newMaxPlayers) {
                          playerCount = newMaxPlayers;
                        }
                      });
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 16),
                  if (isBasketball && isHalfCourt) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Format', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: () {
                        switch (playerCount) {
                          case 2:
                            return '1v1';
                          case 4:
                            return '2v2';
                          case 6:
                            return '3v3';
                          case 8:
                            return '4v4';
                          case 10:
                            return '5v5';
                          default:
                            return '2v2';
                        }
                      }(),
                      items: const [
                        DropdownMenuItem(value: '1v1', child: Text('1v1')),
                        DropdownMenuItem(value: '2v2', child: Text('2v2')),
                        DropdownMenuItem(value: '3v3', child: Text('3v3')),
                        DropdownMenuItem(value: '4v4', child: Text('4v4')),
                        DropdownMenuItem(value: '5v5', child: Text('5v5')),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          switch (value) {
                            case '1v1':
                              playerCount = 2;
                              break;
                            case '2v2':
                              playerCount = 4;
                              break;
                            case '3v3':
                              playerCount = 6;
                              break;
                            case '4v4':
                              playerCount = 8;
                              break;
                            case '5v5':
                              playerCount = 10;
                              break;
                          }
                        });
                      },
                      decoration: const InputDecoration(
                        labelText: 'Game Format',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('Players: $playerCount / 10', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ] else ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Players: $playerCount / $maxPlayers', style: const TextStyle(fontWeight: FontWeight.bold)),
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: playerCount > 0 ? () => setDialogState(() => playerCount--) : null,
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('$playerCount', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: playerCount < maxPlayers ? () => setDialogState(() => playerCount++) : null,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  DropdownButtonFormField<CourtCondition>(
                    value: selectedCondition,
                    decoration: const InputDecoration(
                      labelText: 'Court Condition',
                      border: OutlineInputBorder(),
                    ),
                    items: CourtCondition.values.map((condition) {
                      String label;
                      switch (condition) {
                        case CourtCondition.excellent:
                          label = 'Excellent';
                          break;
                        case CourtCondition.good:
                          label = 'Good';
                          break;
                        case CourtCondition.fair:
                          label = 'Fair';
                          break;
                        case CourtCondition.poor:
                          label = 'Poor';
                          break;
                        case CourtCondition.maintenance:
                          label = 'Maintenance';
                          break;
                      }
                      return DropdownMenuItem(
                        value: condition,
                        child: Text(label),
                      );
                    }).toList(),
                    onChanged: (value) => setDialogState(() => selectedCondition = value!),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final updatedCustomName = customNameController.text.trim();
              
              final updatedCourt = court.copyWith(
                customName: updatedCustomName.isEmpty ? null : updatedCustomName,
                isHalfCourt: isHalfCourt,
                playerCount: playerCount,
                condition: selectedCondition,
                lastUpdated: DateTime.now(),
              );

              try {
                await _parkService.updateCourt(_park.id, updatedCourt);
                
                // If player count was changed, also update it separately for real-time sync
                if (playerCount != court.playerCount) {
                  await _parkService.updateCourtPlayerCount(_park.id, court.id, playerCount);
                }
                
                final updatedPark = await _parkService.getPark(_park.id);
                if (updatedPark != null) {
                  setState(() => _park = updatedPark);
                }
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Court updated successfully!')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to update court: $e')),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemoveCourt(Court court) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Court'),
        content: Text('Are you sure you want to remove Court ${court.courtNumber}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _parkService.removeCourt(_park.id, court.id);
        final updatedPark = await _parkService.getPark(_park.id);
        if (updatedPark != null) {
          setState(() => _park = updatedPark);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Court removed successfully!')),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove court: $e')),
        );
      }
    }
  }

  Future<void> _showScheduleGameDialog() async {
    final user = _authService.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to schedule a game')),
      );
      return;
    }

    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) return;

    if (_park.courts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No courts available at this park')),
      );
      return;
    }

    DateTime selectedDate = DateTime.now().add(const Duration(hours: 1));
    TimeOfDay selectedTime = TimeOfDay.fromDateTime(selectedDate);
    int maxPlayers = 10;
    String skillLevel = 'Any';
    SportType? selectedSportType = _park.courts.first.sportType;
    Court? selectedCourt = _park.courts.first;
    final notesController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Schedule Game'),
        content: StatefulBuilder(
          builder: (context, setDialogState) {
            final filteredCourts = selectedSportType == null 
                ? _park.courts 
                : _park.courts.where((c) => c.sportType == selectedSportType).toList();
            
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<SportType>(
                    value: selectedSportType,
                    decoration: const InputDecoration(
                      labelText: 'Sport Type',
                      border: OutlineInputBorder(),
                    ),
                    items: SportType.values.map((sport) {
                      String label;
                      Widget icon;
                      switch (sport) {
                        case SportType.basketball:
                          label = 'Basketball';
                          icon = const Text('🏀 ', style: TextStyle(fontSize: 16));
                          break;
                        case SportType.pickleballSingles:
                          label = 'Pickleball (Singles)';
                          icon = Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: Image.asset('assets/images/p.jpeg', width: 16, height: 16, fit: BoxFit.contain),
                            ),
                          );
                          break;
                        case SportType.pickleballDoubles:
                          label = 'Pickleball (Doubles)';
                          icon = Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: Image.asset('assets/images/p.jpeg', width: 16, height: 16, fit: BoxFit.contain),
                            ),
                          );
                          break;
                        case SportType.tennisSingles:
                          label = 'Tennis (Singles)';
                          icon = const Text('🎾 ', style: TextStyle(fontSize: 16));
                          break;
                        case SportType.tennisDoubles:
                          label = 'Tennis (Doubles)';
                          icon = const Text('🎾 ', style: TextStyle(fontSize: 16));
                          break;
                      }
                      return DropdownMenuItem(
                        value: sport,
                        child: Row(children: [icon, Text(label)]),
                      );
                    }).toList(),
                    onChanged: (sport) {
                      setDialogState(() {
                        selectedSportType = sport;
                        final filtered = sport == null ? _park.courts : _park.courts.where((c) => c.sportType == sport).toList();
                        selectedCourt = filtered.isNotEmpty ? filtered.first : null;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  if (filteredCourts.isNotEmpty)
                    DropdownButtonFormField<Court>(
                      value: selectedCourt,
                      decoration: const InputDecoration(
                        labelText: 'Court',
                        border: OutlineInputBorder(),
                      ),
                      items: filteredCourts.map((court) {
                        Widget sportIcon;
                        if (court.sportType == SportType.basketball) {
                          sportIcon = const Text('🏀', style: TextStyle(fontSize: 16));
                        } else if (court.sportType == SportType.pickleballSingles || court.sportType == SportType.pickleballDoubles) {
                          sportIcon = ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: Image.asset('assets/images/p.jpeg', width: 16, height: 16, fit: BoxFit.contain),
                          );
                        } else {
                          sportIcon = const Text('🎾', style: TextStyle(fontSize: 16));
                        }
                        return DropdownMenuItem(
                          value: court,
                          child: Row(
                            children: [
                              sportIcon,
                              const SizedBox(width: 6),
                              Text('Court ${court.courtNumber}'),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (court) => setDialogState(() => selectedCourt = court),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: selectedDate,
                              firstDate: DateTime.now(),
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null) {
                              setDialogState(() => selectedDate = picked);
                            }
                          },
                          icon: const Icon(Icons.calendar_today),
                          label: Text('${selectedDate.month}/${selectedDate.day}/${selectedDate.year}'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked = await showTimePicker(
                              context: context,
                              initialTime: selectedTime,
                            );
                            if (picked != null) {
                              setDialogState(() => selectedTime = picked);
                            }
                          },
                          icon: const Icon(Icons.access_time),
                          label: Text(selectedTime.format(context)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Max Players: $maxPlayers', style: const TextStyle(fontWeight: FontWeight.bold)),
                  Slider(
                    value: maxPlayers.toDouble(),
                    min: 2,
                    max: 20,
                    divisions: 18,
                    label: '$maxPlayers players',
                    onChanged: (value) => setDialogState(() => maxPlayers = value.toInt()),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: skillLevel,
                    decoration: const InputDecoration(
                      labelText: 'Skill Level',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'Any', child: Text('Any')),
                      DropdownMenuItem(value: 'Beginner', child: Text('Beginner')),
                      DropdownMenuItem(value: 'Intermediate', child: Text('Intermediate')),
                      DropdownMenuItem(value: 'Advanced', child: Text('Advanced')),
                      DropdownMenuItem(value: 'Pro', child: Text('Pro')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => skillLevel = value);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes (Optional)',
                      hintText: 'Add details about the game...',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (selectedCourt == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please select a court')),
                );
                return;
              }

              final scheduledDateTime = DateTime(
                selectedDate.year,
                selectedDate.month,
                selectedDate.day,
                selectedTime.hour,
                selectedTime.minute,
              );

              final moderatedNotes = Moderation.censorProfanity(notesController.text.trim());
              final game = Game(
                id: '${_park.id}_${DateTime.now().millisecondsSinceEpoch}',
                parkId: _park.id,
                parkName: _park.name,
                courtId: selectedCourt!.id,
                sportType: selectedCourt!.sportType,
                organizerId: user.uid,
                organizerName: appUser.displayName,
                scheduledTime: scheduledDateTime,
                maxPlayers: maxPlayers,
                playerIds: [user.uid],
                playerNames: [appUser.displayName],
                skillLevel: skillLevel == 'Any' ? null : skillLevel,
                notes: moderatedNotes.isEmpty ? null : moderatedNotes,
                createdAt: DateTime.now(),
              );

              try {
                await _gameService.createGame(game);
                await _loadGames();
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(moderatedNotes != notesController.text.trim() ? 'Game scheduled (profanity censored)' : 'Game scheduled successfully!')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to schedule game: $e')),
                );
              }
            },
            child: const Text('Schedule'),
          ),
        ],
      ),
    );
  }

  Future<void> _showReviewDialog() async {
    final user = _authService.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to leave a review')),
      );
      return;
    }

    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) return;

    double rating = 5;
    final commentController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Write a Review'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Rating'),
              const SizedBox(height: 8),
              Row(
                children: List.generate(5, (index) {
                  return IconButton(
                    icon: Icon(
                      index < rating ? Icons.star : Icons.star_border,
                      color: Colors.amber,
                    ),
                    onPressed: () => setDialogState(() => rating = index + 1.0),
                  );
                }),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: commentController,
                decoration: const InputDecoration(
                  labelText: 'Comment',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final review = Review(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                parkId: _park.id,
                userId: user.uid,
                userName: appUser.displayName,
                rating: rating,
                comment: Moderation.censorProfanity(commentController.text.trim()),
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
              );
              
              await _reviewService.createReview(review);
              await _loadReviews();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(review.comment != commentController.text.trim() ? 'Review posted (profanity censored)' : 'Review posted!')),
              );
            },
            child: const Text('Post'),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditReviewDialog(Review review) async {
    double rating = review.rating;
    final commentController = TextEditingController(text: review.comment);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Review'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Rating'),
              const SizedBox(height: 8),
              Row(
                children: List.generate(5, (index) {
                  return IconButton(
                    icon: Icon(
                      index < rating ? Icons.star : Icons.star_border,
                      color: Colors.amber,
                    ),
                    onPressed: () => setDialogState(() => rating = index + 1.0),
                  );
                }),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: commentController,
                decoration: const InputDecoration(
                  labelText: 'Comment',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final updatedReview = Review(
                id: review.id,
                parkId: review.parkId,
                userId: review.userId,
                userName: review.userName,
                rating: rating,
                comment: Moderation.censorProfanity(commentController.text.trim()),
                createdAt: review.createdAt,
                updatedAt: DateTime.now(),
              );
              
              await _reviewService.updateReview(updatedReview);
              await _loadReviews();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(updatedReview.comment != review.comment ? 'Review updated (profanity censored)' : 'Review updated!')),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteReview(Review review) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Review'),
        content: const Text('Are you sure you want to delete this review?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _reviewService.deleteReview(review.id, _park.id);
      await _loadReviews();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Review deleted')),
        );
      }
    }
  }

  Future<void> _cancelGame(Game game) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Game'),
        content: const Text('Are you sure you want to cancel this game? Players will be notified.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Cancel Game'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _gameService.cancelGame(game.id);
      await _loadGames();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Game cancelled')),
        );
      }
    }
  }

  Future<void> _deleteGame(Game game) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Game'),
        content: const Text('Are you sure you want to permanently delete this game?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _gameService.deleteGame(game.id);
      await _loadGames();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Game deleted')),
        );
      }
    }
  }

  Future<void> _showCheckInDialog() async {
    final user = _authService.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to check in')),
      );
      return;
    }

    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) return;

    if (_park.courts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No courts available at this park. Please add a court first.')),
      );
      return;
    }

    debugPrint('DEBUG: Park has ${_park.courts.length} courts');
    for (var court in _park.courts) {
      debugPrint('DEBUG: Court ${court.courtNumber} - sportType: ${court.sportType}');
    }

    int selectedCourtNumber = _park.courts.first.courtNumber;
    int playerCount = 5;
    bool preferDoubles = false;
    // Default to PLAYING. Users can opt-in to queue if they are waiting.
    bool joinQueue = false;
    final notesController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Check In'),
        content: StatefulBuilder(
          builder: (context, setDialogState) {
            final selectedCourt = _park.courts.firstWhere((c) => c.courtNumber == selectedCourtNumber);
            final isPickleballOrTennis = selectedCourt.sportType == SportType.pickleballSingles ||
                selectedCourt.sportType == SportType.pickleballDoubles ||
                selectedCourt.sportType == SportType.tennisSingles ||
                selectedCourt.sportType == SportType.tennisDoubles;
            final isBasketballHalf = selectedCourt.sportType == SportType.basketball && selectedCourt.isHalfCourt;
            final maxAllowed = isPickleballOrTennis
                ? 4
                : getMaxPlayersForSport(selectedCourt.sportType);
            
            debugPrint('DEBUG: Selected court sport type: ${selectedCourt.sportType}');
            debugPrint('DEBUG: isPickleballOrTennis: $isPickleballOrTennis');
            
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  value: selectedCourtNumber,
                  decoration: const InputDecoration(labelText: 'Court Number'),
                  items: _park.courts.map((court) {
                    Widget sportIcon;
                    if (court.sportType == SportType.basketball) {
                      sportIcon = const Text('🏀', style: TextStyle(fontSize: 16));
                    } else if (court.sportType == SportType.pickleballSingles || 
                               court.sportType == SportType.pickleballDoubles) {
                      sportIcon = ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Image.asset('assets/images/p.jpeg', width: 16, height: 16, fit: BoxFit.cover),
                      );
                    } else {
                      sportIcon = const Text('🎾', style: TextStyle(fontSize: 16));
                    }
                    return DropdownMenuItem(
                      value: court.courtNumber,
                      child: Row(
                        children: [
                          sportIcon,
                          const SizedBox(width: 6),
                          Text('Court ${court.courtNumber}'),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (value) => setDialogState(() => selectedCourtNumber = value!),
                ),
                const SizedBox(height: 16),
                if (isBasketballHalf) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Game Format', style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: () {
                      switch (playerCount) {
                        case 2:
                          return '1v1';
                        case 4:
                          return '2v2';
                        case 6:
                          return '3v3';
                        case 8:
                          return '4v4';
                        case 10:
                          return '5v5';
                        default:
                          return '2v2';
                      }
                    }(),
                    items: const [
                      DropdownMenuItem(value: '1v1', child: Text('1v1')),
                      DropdownMenuItem(value: '2v2', child: Text('2v2')),
                      DropdownMenuItem(value: '3v3', child: Text('3v3')),
                      DropdownMenuItem(value: '4v4', child: Text('4v4')),
                      DropdownMenuItem(value: '5v5', child: Text('5v5')),
                    ],
                    onChanged: (value) {
                      setDialogState(() {
                        switch (value) {
                          case '1v1':
                            playerCount = 2;
                            break;
                          case '2v2':
                            playerCount = 4;
                            break;
                          case '3v3':
                            playerCount = 6;
                            break;
                          case '4v4':
                            playerCount = 8;
                            break;
                          case '5v5':
                            playerCount = 10;
                            break;
                        }
                      });
                    },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Players: $playerCount', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ] else ...[
                  Row(
                    children: [
                      const Text('Players:'),
                      IconButton(
                        icon: const Icon(Icons.remove),
                        onPressed: playerCount > 0 ? () => setDialogState(() => playerCount--) : null,
                      ),
                      Text('$playerCount', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: playerCount < maxAllowed ? () => setDialogState(() => playerCount++) : null,
                      ),
                    ],
                  ),
                ],
                if (isPickleballOrTennis) ...[
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    title: const Text('Looking for doubles'),
                    value: preferDoubles,
                    onChanged: (value) => setDialogState(() => preferDoubles = value ?? false),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
                const SizedBox(height: 8),
                CheckboxListTile(
                  title: const Text("I'm waiting (join queue)"),
                  subtitle: const Text('If checked, you will be added to the waiting list'),
                  value: joinQueue,
                  onChanged: (value) => setDialogState(() => joinQueue = value ?? true),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final selectedCourt = _park.courts.firstWhere((c) => c.courtNumber == selectedCourtNumber);
              final isPickleballOrTennis = selectedCourt.sportType == SportType.pickleballSingles ||
                  selectedCourt.sportType == SportType.pickleballDoubles ||
                  selectedCourt.sportType == SportType.tennisSingles ||
                  selectedCourt.sportType == SportType.tennisDoubles;
              
               final moderatedNotes = Moderation.censorProfanity(notesController.text.trim());
               final checkIn = CheckIn(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                parkId: _park.id,
                parkName: _park.name,
                userId: user.uid,
                userName: appUser.displayName,
                courtNumber: selectedCourtNumber,
                playerCount: playerCount,
                preferDoubles: isPickleballOrTennis ? preferDoubles : null,
                 notes: moderatedNotes,
                checkInTime: DateTime.now(),
                 // If joining queue, this is not an active on-court check-in
                 inQueue: joinQueue,
                 isActive: !joinQueue,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
              );
              
               await _checkInService.createCheckIn(checkIn);
              
              if (joinQueue) {
                await _parkService.joinQueue(_park.id, selectedCourt.id, user.uid, appUser.displayName);
              }
              
              await _notificationService.sendCheckInNotification(_park.id, _park.name, appUser.displayName);
              
              await _loadCheckIns();
              await _loadActiveCheckIn();
              
              final updatedPark = await _parkService.getPark(_park.id);
              if (updatedPark != null) {
                setState(() => _park = updatedPark);
              }
              
               Navigator.pop(context);
               ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(moderatedNotes != notesController.text.trim() ? 'Checked in (profanity censored)' : 'Checked in!')),
               );
            },
            child: const Text('Check In'),
          ),
        ],
      ),
    );
  }

  Future<void> _leaveCourt() async {
    if (_activeCheckIn == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave Court'),
        content: Text('Are you sure you want to check out from Court ${_activeCheckIn!.courtNumber}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary),
            child: const Text('Leave Court', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _checkInService.checkOut(_activeCheckIn!.id);
        await _loadCheckIns();
        await _loadActiveCheckIn();
        // Refresh park to reflect updated player counts immediately after checkout
        final updatedPark = await _parkService.getPark(_park.id);
        if (updatedPark != null && mounted) {
          setState(() => _park = updatedPark);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You have left the court')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to check out: $e')),
          );
        }
      }
    }
  }

  String _getTimeAgo(DateTime dateTime) {
    final difference = DateTime.now().difference(dateTime);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(theme),
            TabBar(
              controller: _tabController,
              labelColor: theme.colorScheme.primary,
              unselectedLabelColor: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              indicatorColor: theme.colorScheme.primary,
              tabs: const [
                Tab(text: 'Courts'),
                Tab(text: 'Reviews'),
                Tab(text: 'Games'),
                Tab(text: 'Activity'),
              ],
            ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildCourtsTab(theme),
                        _buildReviewsTab(theme),
                        _buildGamesTab(theme),
                        _buildActivityTab(theme),
                      ],
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_activeCheckIn != null)
            FloatingActionButton.extended(
              heroTag: 'leaveCourt',
              onPressed: _leaveCourt,
              backgroundColor: Colors.orange,
              icon: const Icon(Icons.logout, color: Colors.white),
              label: const Text('Leave Court', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            )
          else
            FloatingActionButton(
              heroTag: 'checkin',
              onPressed: _showCheckInDialog,
              backgroundColor: theme.colorScheme.secondary,
              child: const Icon(Icons.add_location_alt, color: Colors.white),
            ),
          const SizedBox(height: 12),
          if (_isFavorite)
            FloatingActionButton(
              heroTag: 'notifications',
              onPressed: _toggleNotifications,
              backgroundColor: _favoriteNotificationEnabled ? theme.colorScheme.tertiary : theme.colorScheme.surface,
              child: Icon(
                _favoriteNotificationEnabled ? Icons.notifications_active : Icons.notifications_off,
                color: _favoriteNotificationEnabled ? Colors.white : theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          if (_isFavorite) const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'favorite',
            onPressed: _toggleFavorite,
            backgroundColor: _isFavorite ? Colors.red : theme.colorScheme.surface,
            child: Icon(
              _isFavorite ? Icons.favorite : Icons.favorite_border,
              color: _isFavorite ? Colors.white : theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_park.photoUrls.isNotEmpty)
          SizedBox(
            height: 200,
            child: PageView.builder(
              itemCount: _park.photoUrls.length,
              itemBuilder: (context, index) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      _park.photoUrls[index],
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          color: theme.colorScheme.primary.withValues(alpha: 0.1),
                          child: Icon(Icons.sports_basketball, size: 64, color: theme.colorScheme.primary.withValues(alpha: 0.3)),
                        );
                      },
                    ),
                    Positioned(
                      top: 16,
                      left: 16,
                      child: CircleAvatar(
                        backgroundColor: Colors.black.withValues(alpha: 0.5),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
                  child: IconButton(
                    icon: Icon(Icons.arrow_back, color: theme.colorScheme.primary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _park.name,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.qr_code_scanner),
                    tooltip: 'Scan QR to Check In',
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const QrScannerPage()),
                      );
                    },
                    color: theme.colorScheme.primary,
                  ),
                  IconButton(
                    icon: Icon(_isUploadingPhoto ? Icons.hourglass_bottom : Icons.add_photo_alternate),
                    onPressed: _isUploadingPhoto ? null : _uploadPhoto,
                    color: theme.colorScheme.primary,
                  ),
                  if (_isAdmin)
                    PopupMenuButton<String>(
                      tooltip: 'Admin actions',
                      onSelected: (value) async {
                        if (value == 'delete') {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Delete Park'),
                              content: const Text('This will permanently remove the park and its data. Continue?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                                  child: const Text('Delete', style: TextStyle(color: Colors.white)),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            try {
                              await _parkService.deletePark(_park.id);
                              if (mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Park deleted')),
                                );
                              }
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Failed to delete park: $e')),
                                );
                              }
                            }
                          }
                        }
                      },
                      itemBuilder: (ctx) => const [
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete, size: 18, color: Colors.red),
                              SizedBox(width: 8),
                              Text('Delete Park', style: TextStyle(color: Colors.red)),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.location_on, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _park.address,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                  ),
                ],
              ),
              if (_park.averageRating > 0) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.star, size: 18, color: Colors.amber),
                    const SizedBox(width: 4),
                    Text(
                      _park.averageRating.toStringAsFixed(1),
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      ' (${_park.totalReviews} reviews)',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ],
              if (_park.description != null && _park.description!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _park.description!,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCourtsTab(ThemeData theme) {
    final totalPlayers = _park.courts.fold(0, (sum, court) => sum + court.playerCount);
    
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [theme.colorScheme.primary, theme.colorScheme.secondary],
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total Courts', style: theme.textTheme.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.8))),
                    const SizedBox(height: 4),
                    Text('${_park.courts.length}', style: theme.textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              Container(width: 1, height: 50, color: Colors.white.withValues(alpha: 0.3)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Active Players', style: theme.textTheme.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.8))),
                    const SizedBox(height: 4),
                    Text('$totalPlayers', style: theme.textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _showAddCourtDialog,
          icon: const Icon(Icons.add, color: Colors.white),
          label: const Text('Add Court', style: TextStyle(color: Colors.white)),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.tertiary,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 20),
        ..._park.courts.map((court) {
          final user = _authService.currentUser;
          final isInQueue = user != null && court.gotNextQueue.any((p) => p.userId == user.uid);
          
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: CourtFlipCard(
              court: court,
              theme: theme,
              onEdit: () => _showEditCourtDialog(court),
              onRemove: () => _confirmRemoveCourt(court),
              onQueueAction: (isInQueue) => _handleQueueAction(court, isInQueue),
              onMarkAsPlaying: (userId, userName) => _markPlayerAsPlaying(court, userId, userName),
              onStillWaiting: (userId, userName) => _handleStillWaiting(court, userId, userName),
              isInQueue: isInQueue,
              isUserLoggedIn: user != null,
              // QR generation removed: courts now support scanning only via physical codes
            ),
          );
        }),
      ],
    );
  }


  Future<void> _handleQueueAction(Court court, bool isInQueue) async {
    final user = _authService.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to join the queue')),
      );
      return;
    }

    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) return;

    setState(() => _isLoading = true);
    try {
      if (isInQueue) {
        await _parkService.leaveQueue(_park.id, court.id, user.uid);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Left the queue')),
        );
      } else {
        await _parkService.joinQueue(_park.id, court.id, user.uid, appUser.displayName);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Joined the queue!')),
        );
      }
      
      final updatedPark = await _parkService.getPark(_park.id);
      if (updatedPark != null) {
        setState(() => _park = updatedPark);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _markPlayerAsPlaying(Court court, String userId, String userName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Now Playing'),
        content: Text('Mark $userName as now playing on Court ${court.courtNumber}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.tertiary),
            child: const Text('Now Playing', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      try {
        // Always remove from queue first
        await _parkService.leaveQueue(_park.id, court.id, userId);

        // If the user marked as playing is the current user, also create an active check-in
        final current = _authService.currentUser;
        if (current != null && current.uid == userId) {
          // If they already have an active check-in elsewhere, end it to avoid duplicates
          final existing = await _checkInService.getActiveCheckIn(userId);
          if (existing != null) {
            try {
              await _checkInService.checkOut(existing.id);
            } catch (_) {}
          }

          final checkIn = CheckIn(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            parkId: _park.id,
            parkName: _park.name,
            userId: userId,
            userName: userName,
            courtNumber: court.courtNumber,
            // Default to a single player when coming from queue → playing
            playerCount: 1,
            preferDoubles: null,
            notes: null,
            checkInTime: DateTime.now(),
            inQueue: false,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );

          await _checkInService.createCheckIn(checkIn);

          // Also send the standard check-in notification
          await _notificationService.sendCheckInNotification(_park.id, _park.name, userName);

          // Refresh local state including active check-in so the Leave Court FAB appears
          await _loadCheckIns();
          await _loadActiveCheckIn();
        }

        final updatedPark = await _parkService.getPark(_park.id);
        if (updatedPark != null) {
          setState(() => _park = updatedPark);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$userName is now playing!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: ${e.toString()}')),
          );
        }
      } finally {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleStillWaiting(Court court, String userId, String userName) async {
    setState(() => _isLoading = true);
    try {
      await _parkService.refreshQueueActivity(_park.id, court.id, userId);
      final updatedPark = await _parkService.getPark(_park.id);
      if (updatedPark != null) {
        setState(() => _park = updatedPark);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$userName\'s queue time refreshed')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }


  Widget _buildReviewsTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ElevatedButton.icon(
          onPressed: _showReviewDialog,
          icon: const Icon(Icons.rate_review, color: Colors.white),
          label: const Text('Write a Review', style: TextStyle(color: Colors.white)),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 20),
        if (_reviews.isEmpty)
          Center(
            child: Column(
              children: [
                const SizedBox(height: 40),
                Icon(Icons.rate_review, size: 64, color: theme.colorScheme.onSurface.withValues(alpha: 0.2)),
                const SizedBox(height: 16),
                Text('No reviews yet', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
                const SizedBox(height: 8),
                Text('Be the first to review this park!', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.4))),
              ],
            ),
          )
        else
          ..._reviews.map((review) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _buildReviewCard(review, theme),
          )),
      ],
    );
  }

  Widget _buildReviewCard(Review review, ThemeData theme) {
    final user = _authService.currentUser;
    final isAuthor = user != null && review.userId == user.uid;
    final canEdit = _isAdmin || isAuthor;
    final canDelete = _isAdmin || isAuthor;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                child: Text(review.userName[0].toUpperCase(), style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(review.userName, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                        if (_isAdmin) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('ADMIN', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.red)),
                          ),
                        ],
                      ],
                    ),
                    Row(
                      children: List.generate(5, (index) {
                        return Icon(
                          index < review.rating ? Icons.star : Icons.star_border,
                          color: Colors.amber,
                          size: 16,
                        );
                      }),
                    ),
                  ],
                ),
              ),
              Text(_getTimeAgo(review.createdAt), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
              if (canEdit || canDelete) ...[
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (value) {
                    if (value == 'edit') {
                      _showEditReviewDialog(review);
                    } else if (value == 'delete') {
                      _deleteReview(review);
                    } else if (value == 'report') {
                      _showReportDialogForReview(review);
                    }
                  },
                  itemBuilder: (context) => [
                    if (canEdit) const PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit, size: 18), SizedBox(width: 8), Text('Edit')])),
                    if (canDelete) const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete, size: 18, color: Colors.red), SizedBox(width: 8), Text('Delete', style: TextStyle(color: Colors.red))])),
                    const PopupMenuItem(value: 'report', child: Row(children: [Icon(Icons.flag, size: 18), SizedBox(width: 8), Text('Report')]))
                  ],
                ),
              ],
            ],
          ),
          if (review.comment.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(review.comment, style: theme.textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }

  Widget _buildGamesTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ElevatedButton.icon(
          onPressed: _showScheduleGameDialog,
          icon: const Icon(Icons.event, color: Colors.white),
          label: const Text('Schedule Game', style: TextStyle(color: Colors.white)),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.secondary,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 20),
        if (_games.isEmpty)
          Center(
            child: Column(
              children: [
                const SizedBox(height: 40),
                Icon(Icons.sports_basketball, size: 64, color: theme.colorScheme.onSurface.withValues(alpha: 0.2)),
                const SizedBox(height: 16),
                Text('No upcoming games', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
              ],
            ),
          )
        else
          ..._games.map((game) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildGameCard(game, theme),
          )),
      ],
    );
  }

  Widget _buildGameCard(Game game, ThemeData theme) {
    final isOpen = game.status == GameStatus.scheduled && game.playerIds.length < game.maxPlayers;
    final user = _authService.currentUser;
    final canDelete = _isAdmin || (user != null && game.organizerId == user.uid);

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => GameDetailPage(game: game)),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(game.notes ?? 'Pickup Game', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isOpen
                        ? theme.colorScheme.tertiary.withValues(alpha: 0.1)
                        : theme.colorScheme.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isOpen ? 'Open' : 'Full',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isOpen ? theme.colorScheme.tertiary : theme.colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (canDelete)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (value) {
                      if (value == 'cancel') {
                        _cancelGame(game);
                      } else if (value == 'delete') {
                        _deleteGame(game);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'cancel', child: Row(children: [Icon(Icons.cancel, size: 18), SizedBox(width: 8), Text('Cancel Game')])),
                      const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete, size: 18, color: Colors.red), SizedBox(width: 8), Text('Delete', style: TextStyle(color: Colors.red))])),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.event, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                const SizedBox(width: 4),
                Text(
                  '${game.scheduledTime.month}/${game.scheduledTime.day} at ${game.scheduledTime.hour}:${game.scheduledTime.minute.toString().padLeft(2, '0')}',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
                const SizedBox(width: 16),
                Icon(Icons.people, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                const SizedBox(width: 4),
                Text('${game.playerIds.length}/${game.maxPlayers}', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivityTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_checkIns.isEmpty)
          Center(
            child: Column(
              children: [
                const SizedBox(height: 40),
                Icon(Icons.location_on, size: 64, color: theme.colorScheme.onSurface.withValues(alpha: 0.2)),
                const SizedBox(height: 16),
                Text('No recent activity', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
              ],
            ),
          )
        else
          ..._checkIns.map((checkIn) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildCheckInCard(checkIn, theme),
          )),
      ],
    );
  }

  Widget _buildCheckInCard(CheckIn checkIn, ThemeData theme) {
    final user = _authService.currentUser;
    final canDelete = _isAdmin || (user != null && checkIn.userId == user.uid);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: theme.colorScheme.secondary.withValues(alpha: 0.2),
                child: Text(checkIn.userName[0].toUpperCase(), style: TextStyle(color: theme.colorScheme.secondary, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Show clear "is playing" phrasing per requested UX
                    RichText(
                      text: TextSpan(
                        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurface),
                        children: [
                          TextSpan(text: checkIn.userName, style: const TextStyle(fontWeight: FontWeight.bold)),
                          const TextSpan(text: ' is playing on '),
                          TextSpan(text: 'Court ${checkIn.courtNumber}', style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${checkIn.playerCount} players${checkIn.preferDoubles == true ? ' • Looking for doubles' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                  ],
                ),
              ),
              Text(
                DateFormat('MMM dd, yyyy').format(checkIn.createdAt),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
              ),
              if (canDelete)
                IconButton(
                  icon: const Icon(Icons.close, size: 20, color: Colors.red),
                  onPressed: () => _deleteCheckIn(checkIn),
                  tooltip: 'Remove check-in',
                ),
            ],
          ),
          if (checkIn.notes != null && checkIn.notes!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(checkIn.notes!, style: theme.textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }

  Future<void> _deleteCheckIn(CheckIn checkIn) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Check-in'),
        content: const Text('Are you sure you want to remove this check-in?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _checkInService.deleteCheckIn(checkIn.id);
      await _loadCheckIns();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Check-in removed')),
        );
      }
    }
  }
}
