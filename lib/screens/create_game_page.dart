import 'package:flutter/material.dart';
import 'package:hoopsight/models/game_model.dart';
import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/models/group_model.dart';
import 'package:hoopsight/models/invite_model.dart';
import 'package:hoopsight/models/user_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/game_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/group_service.dart';
import 'package:hoopsight/services/invite_service.dart';
import 'package:hoopsight/utils/moderation.dart';

class CreateGamePage extends StatefulWidget {
  final Park park;

  const CreateGamePage({super.key, required this.park});

  @override
  State<CreateGamePage> createState() => _CreateGamePageState();
}

class _CreateGamePageState extends State<CreateGamePage> {
  final AuthService _authService = AuthService();
  final GameService _gameService = GameService();
  final UserService _userService = UserService();
  final GroupService _groupService = GroupService();
  final InviteService _inviteService = InviteService();
  final TextEditingController _notesController = TextEditingController();
  
  DateTime _selectedDate = DateTime.now().add(const Duration(hours: 1));
  TimeOfDay _selectedTime = TimeOfDay.now();
  int _maxPlayers = 10;
  String _skillLevel = 'Any';
  SportType? _selectedSportType;
  Court? _selectedCourt;
  bool _isCreating = false;
  
  // Invite related state
  List<AppUser> _friends = [];
  List<FriendGroup> _groups = [];
  Set<String> _selectedFriendIds = {};
  Set<String> _selectedGroupIds = {};
  bool _isLoadingInviteData = false;
  bool _showInviteSection = false;

  @override
  void initState() {
    super.initState();
    if (widget.park.courts.isNotEmpty) {
      _selectedSportType = widget.park.courts.first.sportType;
      _selectedCourt = widget.park.courts.first;
    }
    _loadInviteData();
  }

  Future<void> _loadInviteData() async {
    final user = _authService.currentUser;
    if (user == null) return;

    setState(() => _isLoadingInviteData = true);

    try {
      final appUser = await _userService.getUser(user.uid);
      if (appUser != null && appUser.friendIds.isNotEmpty) {
        final rawFriends = await _userService.getFriends(appUser.friendIds);
        final friends = rawFriends
            .where((f) => !appUser.blockedUserIds.contains(f.id) && !f.blockedUserIds.contains(appUser.id))
            .toList();
        final groups = await _groupService.getUserGroups(user.uid);
        
        setState(() {
          _friends = friends;
          _groups = groups;
        });
      }
    } catch (e) {
      debugPrint('Error loading invite data: $e');
    } finally {
      setState(() => _isLoadingInviteData = false);
    }
  }

  List<Court> _getFilteredCourts() {
    if (_selectedSportType == null) return widget.park.courts;
    return widget.park.courts.where((c) => c.sportType == _selectedSportType).toList();
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _selectTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
    );

    if (picked != null) {
      setState(() => _selectedTime = picked);
    }
  }

  Future<void> _sendGameInvites(Game game, String senderId, String senderName) async {
    final invitedUserIds = <String>[];
    final invitedUserNames = <String>[];

    // Add selected friends
    for (final friendId in _selectedFriendIds) {
      final friend = _friends.firstWhere((f) => f.id == friendId);
      invitedUserIds.add(friendId);
      invitedUserNames.add(friend.displayName);
    }

    // Add members from selected groups
    for (final groupId in _selectedGroupIds) {
      final group = _groups.firstWhere((g) => g.id == groupId);
      invitedUserIds.addAll(group.memberIds);
      invitedUserNames.addAll(group.memberNames);
    }

    // Remove duplicates and sender
    final uniqueUserIds = invitedUserIds.toSet().where((id) => id != senderId).toList();
    final uniqueUserNames = <String>[];
    final addedIds = <String>{};
    
    for (int i = 0; i < invitedUserIds.length; i++) {
      if (!addedIds.contains(invitedUserIds[i]) && invitedUserIds[i] != senderId) {
        addedIds.add(invitedUserIds[i]);
        uniqueUserNames.add(invitedUserNames[i]);
      }
    }

    // Enforce: interactions limited to invited friends only and not blocked either way
    final sender = await _userService.getUser(senderId);
    final senderFriends = sender?.friendIds.toSet() ?? <String>{};
    final senderBlocked = sender?.blockedUserIds.toSet() ?? <String>{};
    final filteredIds = <String>[];
    final filteredNames = <String>[];
    for (int i = 0; i < uniqueUserIds.length; i++) {
      final uid = uniqueUserIds[i];
      if (!senderFriends.contains(uid)) continue;
      if (senderBlocked.contains(uid)) continue;
      final friend = _friends.where((f) => f.id == uid).cast<AppUser?>().firstWhere((f) => f != null, orElse: () => null);
      if (friend != null && friend.blockedUserIds.contains(senderId)) continue;
      filteredIds.add(uid);
      filteredNames.add(uniqueUserNames[i]);
    }

    if (filteredIds.isNotEmpty) {
      final invite = GameInvite(
        id: '${game.id}_invite_${DateTime.now().millisecondsSinceEpoch}',
        gameId: game.id,
        gameName: '${game.parkName} Game',
        parkId: game.parkId,
        parkName: game.parkName,
        courtId: game.courtId,
        courtNumber: _selectedCourt?.courtNumber ?? 1,
        sportType: game.sportType,
        senderId: senderId,
        senderName: senderName,
        invitedUserIds: filteredIds,
        invitedUserNames: filteredNames,
        type: InviteType.scheduledGame,
        scheduledTime: game.scheduledTime,
        createdAt: DateTime.now(),
      );

      await _inviteService.sendGameInvites(invite);
    }
  }

  Future<void> _createGame() async {
    final user = _authService.currentUser;
    if (user == null || _selectedCourt == null) return;

    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) return;

    setState(() => _isCreating = true);

    try {
      final scheduledDateTime = DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );

      final moderatedNotes = Moderation.censorProfanity(_notesController.text.trim());
      final game = Game(
        id: '${widget.park.id}_${DateTime.now().millisecondsSinceEpoch}',
        parkId: widget.park.id,
        parkName: widget.park.name,
        courtId: _selectedCourt!.id,
        sportType: _selectedCourt!.sportType,
        organizerId: user.uid,
        organizerName: appUser.displayName,
        scheduledTime: scheduledDateTime,
        maxPlayers: _maxPlayers,
        playerIds: [user.uid],
        playerNames: [appUser.displayName],
        skillLevel: _skillLevel == 'Any' ? null : _skillLevel,
        notes: moderatedNotes.isEmpty ? null : moderatedNotes,
        createdAt: DateTime.now(),
      );

      await _gameService.createGame(game);

      // Send invites if any are selected
      await _sendGameInvites(game, user.uid, appUser.displayName);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(moderatedNotes != _notesController.text.trim() ? 'Game created (profanity censored)' : 'Game created successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create game: $e')),
        );
      }
    } finally {
      setState(() => _isCreating = false);
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Game'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Park',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(widget.park.name),
            const SizedBox(height: 24),
            Text(
              'Sport Type',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<SportType>(
              value: _selectedSportType,
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
                    children: [
                      icon,
                      Text(label),
                    ],
                  ),
                );
              }).toList(),
              onChanged: (sport) {
                setState(() {
                  _selectedSportType = sport;
                  final filteredCourts = _getFilteredCourts();
                  _selectedCourt = filteredCourts.isNotEmpty ? filteredCourts.first : null;
                });
              },
            ),
            const SizedBox(height: 24),
            Text(
              'Court',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<Court>(
              value: _selectedCourt,
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              items: _getFilteredCourts().map((court) {
                Widget sportIcon;
                switch (court.sportType) {
                  case SportType.basketball:
                    sportIcon = const Text('🏀', style: TextStyle(fontSize: 16));
                    break;
                  case SportType.pickleballSingles:
                  case SportType.pickleballDoubles:
                    sportIcon = ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Image.asset('assets/images/pickleball.jpeg', width: 16, height: 16, fit: BoxFit.cover),
                    );
                    break;
                  case SportType.tennisSingles:
                  case SportType.tennisDoubles:
                    sportIcon = const Text('🎾', style: TextStyle(fontSize: 16));
                    break;
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
              onChanged: (court) {
                setState(() => _selectedCourt = court);
              },
            ),
            const SizedBox(height: 24),
            Text(
              'Date & Time',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _selectDate,
                    icon: const Icon(Icons.calendar_today),
                    label: Text('${_selectedDate.month}/${_selectedDate.day}/${_selectedDate.year}'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _selectTime,
                    icon: const Icon(Icons.access_time),
                    label: Text(_selectedTime.format(context)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'Max Players',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Slider(
              value: _maxPlayers.toDouble(),
              min: 2,
              max: 20,
              divisions: 18,
              label: '$_maxPlayers players',
              onChanged: (value) {
                setState(() => _maxPlayers = value.toInt());
              },
            ),
            Text('$_maxPlayers players', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            Text(
              'Skill Level',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _skillLevel,
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
                  setState(() => _skillLevel = value);
                }
              },
            ),
            const SizedBox(height: 24),
            Text(
              'Notes (Optional)',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notesController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Add any additional details about the game...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 24),
            // Invite Friends & Groups Section
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.person_add, color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          'Invite Friends & Groups',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: Icon(_showInviteSection ? Icons.expand_less : Icons.expand_more),
                          onPressed: () {
                            setState(() => _showInviteSection = !_showInviteSection);
                          },
                        ),
                      ],
                    ),
                    if (_showInviteSection) ...[
                      const Divider(),
                      if (_isLoadingInviteData)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else ...[
                        // Friends Section
                        if (_friends.isNotEmpty) ...[
                          Text(
                            'Friends',
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          ...(_friends.map((friend) => CheckboxListTile(
                                title: Text(friend.displayName),
                                value: _selectedFriendIds.contains(friend.id),
                                onChanged: (bool? value) {
                                  setState(() {
                                    if (value == true) {
                                      _selectedFriendIds.add(friend.id);
                                    } else {
                                      _selectedFriendIds.remove(friend.id);
                                    }
                                  });
                                },
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ))),
                          if (_groups.isNotEmpty) const SizedBox(height: 16),
                        ],
                        // Groups Section
                        if (_groups.isNotEmpty) ...[
                          Text(
                            'Groups',
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          ...(_groups.map((group) => CheckboxListTile(
                                title: Text(group.name),
                                subtitle: Text('${group.memberNames.length} members'),
                                value: _selectedGroupIds.contains(group.id),
                                onChanged: (bool? value) {
                                  setState(() {
                                    if (value == true) {
                                      _selectedGroupIds.add(group.id);
                                    } else {
                                      _selectedGroupIds.remove(group.id);
                                    }
                                  });
                                },
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ))),
                        ],
                        if (_friends.isEmpty && _groups.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'No friends or groups available to invite.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isCreating ? null : _createGame,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isCreating
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Create Game',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
