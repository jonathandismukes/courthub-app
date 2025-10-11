import 'package:flutter/material.dart';
import 'package:hoopsight/models/user_model.dart';
import 'package:hoopsight/models/game_model.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/game_service.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/screens/game_detail_page.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hoopsight/models/report_model.dart';
import 'package:hoopsight/services/report_service.dart';
import 'package:hoopsight/services/storage_service.dart';

class UserProfilePage extends StatefulWidget {
  final String userId;

  const UserProfilePage({super.key, required this.userId});

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  final UserService _userService = UserService();
  final GameService _gameService = GameService();
  final AuthService _authService = AuthService();
  final ReportService _reportService = ReportService();
  final StorageService _storageService = StorageService();
  
  AppUser? _user;
  List<Game> _userGames = [];
  bool _isLoading = true;
  bool _isFriend = false;
  String? _currentUserId;
  bool _isBlocked = false;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  Future<void> _loadUserProfile() async {
    setState(() => _isLoading = true);

    try {
      final firebaseUser = _authService.currentUser;
      _currentUserId = firebaseUser?.uid;

      final user = await _userService.getUser(widget.userId);
      if (user != null) {
        final games = await _gameService.getUserGames(widget.userId);
        
        bool isFriend = false;
        if (_currentUserId != null) {
          final currentUser = await _userService.getUser(_currentUserId!);
          isFriend = currentUser?.friendIds.contains(widget.userId) ?? false;
          _isBlocked = currentUser?.blockedUserIds.contains(widget.userId) ?? false;
        }

        setState(() {
          _user = user;
          _userGames = games;
          _isFriend = isFriend;
           _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleFriend() async {
    if (_currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please login to add friends')),
      );
      return;
    }

    try {
      if (_isFriend) {
        await _userService.removeFriend(_currentUserId!, widget.userId);
        await _userService.removeFriend(widget.userId, _currentUserId!);
        setState(() => _isFriend = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Friend removed')),
          );
        }
      } else {
        await _userService.addFriend(_currentUserId!, widget.userId);
        await _userService.addFriend(widget.userId, _currentUserId!);
        setState(() => _isFriend = true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Friend added!')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update friend status')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOwnProfile = _currentUserId == widget.userId;

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: const Center(child: Text('User not found')),
      );
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            actions: [
              if (!isOwnProfile && _currentUserId != null)
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'report') {
                      _showReportDialogProfile();
                    } else if (value == 'block') {
                      _toggleBlockUser();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'report', child: Row(children: [Icon(Icons.flag, size: 18), SizedBox(width: 8), Text('Report Profile')])),
                    PopupMenuItem(
                      value: 'block',
                      child: Row(children: [
                        Icon(_isBlocked ? Icons.lock_open : Icons.block, size: 18, color: Colors.red),
                        const SizedBox(width: 8),
                        Text(_isBlocked ? 'Unblock User' : 'Block User', style: const TextStyle()),
                      ]),
                    ),
                  ],
                ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      theme.colorScheme.primary,
                      theme.colorScheme.secondary,
                    ],
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      CircleAvatar(
                        radius: 50,
                        backgroundColor: Colors.white,
                        child: _user!.photoUrl != null
                            ? ClipOval(
                                child: Image.network(
                                  _user!.photoUrl!,
                                  width: 100,
                                  height: 100,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : Icon(
                                Icons.person,
                                size: 50,
                                color: theme.colorScheme.primary,
                              ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _user!.displayName,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _user!.skillLevel,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                      if (_user!.bio != null) ...[
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            _user!.bio!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.8),
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              children: [
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _StatCard(
                        label: 'Games',
                        value: '${_user!.gamesPlayed}',
                      ),
                      _StatCard(
                        label: 'Favorites',
                        value: '${_user!.favoriteParkIds.length}',
                      ),
                      _StatCard(
                        label: 'Friends',
                        value: '${_user!.friendIds.length}',
                      ),
                    ],
                  ),
                ),
                if (!isOwnProfile && _currentUserId != null) ...[
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ElevatedButton.icon(
                      onPressed: _isBlocked ? null : _toggleFriend,
                      icon: Icon(_isFriend ? Icons.person_remove : Icons.person_add),
                      label: Text(_isFriend ? 'Remove Friend' : 'Add Friend'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                        backgroundColor: _isFriend 
                            ? theme.colorScheme.error.withValues(alpha: 0.1)
                            : theme.colorScheme.primary,
                        foregroundColor: _isFriend 
                            ? theme.colorScheme.error
                            : Colors.white,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.sports_basketball,
                        color: theme.colorScheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Games (${_userGames.length})',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _userGames.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            Icon(
                              Icons.sports_basketball_outlined,
                              size: 48,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No games yet',
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _userGames.length,
                        itemBuilder: (context, index) {
                          final game = _userGames[index];
                          return _GameCard(game: game);
                        },
                      ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleBlockUser() async {
    if (_currentUserId == null) return;
    try {
      if (_isBlocked) {
        await _userService.unblockUser(_currentUserId!, widget.userId);
        setState(() => _isBlocked = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User unblocked')));
        }
      } else {
        await _userService.blockUser(_currentUserId!, widget.userId);
        setState(() {
          _isBlocked = true;
          _isFriend = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User blocked')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _showReportDialogProfile() async {
    final reasons = ['Inappropriate messages', 'Offensive profile', 'Spam', 'Other'];
    String selectedReason = reasons.first;
    final notesController = TextEditingController();
    PlatformFile? pickedFile;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: const Text('Report Profile'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: selectedReason,
                items: reasons.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
                onChanged: (v) => setStateDialog(() => selectedReason = v ?? reasons.first),
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
                      setStateDialog(() => pickedFile = result.files.first);
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
                  targetId: widget.userId,
                  targetType: ReportTargetType.profile,
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
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;

  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _GameCard extends StatelessWidget {
  final Game game;

  const _GameCard({required this.game});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOpen = game.playerIds.length < game.maxPlayers;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GameDetailPage(game: game),
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      game.parkName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: isOpen
                          ? Colors.green.withValues(alpha: 0.1)
                          : Colors.grey.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      isOpen ? 'Open' : 'Full',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isOpen ? Colors.green : Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.access_time,
                    size: 16,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatDateTime(game.scheduledTime),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Icon(
                    Icons.people,
                    size: 16,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${game.playerIds.length}/${game.maxPlayers}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final gameDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

    String dateStr;
    if (gameDate == today) {
      dateStr = 'Today';
    } else if (gameDate == today.add(const Duration(days: 1))) {
      dateStr = 'Tomorrow';
    } else {
      dateStr = '${dateTime.month}/${dateTime.day}';
    }

    final hour = dateTime.hour > 12 ? dateTime.hour - 12 : dateTime.hour;
    final period = dateTime.hour >= 12 ? 'PM' : 'AM';
    return '$dateStr at $hour:${dateTime.minute.toString().padLeft(2, '0')} $period';
  }
}

 
