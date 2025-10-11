import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:hoopsight/utils/qr_utils.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/game_service.dart';
import 'package:hoopsight/services/checkin_service.dart';
import 'package:hoopsight/services/park_service.dart';
import 'package:hoopsight/services/cloud_park_service.dart';
import 'package:hoopsight/models/checkin_model.dart';
import 'package:hoopsight/models/park_model.dart';

// Top-level enum for user-facing sport categories
enum _SportCategory { basketball, pickleball, tennis }

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  // Web-safe: we removed camera scanning to avoid incompatible web plugin.
  // Manual entry remains available across platforms. You can re-enable
  // camera scanning later using a web-compatible package.
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final GameService _gameService = GameService();
  final CheckInService _checkInService = CheckInService();
  final ParkService _parkService = ParkService();
  final CloudParkService _cloudParkService = CloudParkService();

  bool _handled = false;
  String _lastError = '';

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _handleRawValue(String value) async {
    if (_handled) return;
    setState(() => _handled = true);
    final action = QrUtils.parse(value);

    switch (action.type) {
      case QrActionType.invite:
        await _handleInvite(action.params['gameId']);
        break;
      case QrActionType.checkin:
        await _handleCheckIn(action.params);
        break;
      case QrActionType.unknown:
        setState(() {
          _lastError = 'Unrecognized QR code.';
          _handled = false;
        });
        break;
    }
  }

  Future<void> _handleInvite(String? gameId) async {
    if (gameId == null) {
      _showSnack('Invalid invite');
      setState(() => _handled = false);
      return;
    }
    final user = _authService.currentUser;
    if (user == null) {
      _showSnack('Please sign in to join games');
      setState(() => _handled = false);
      return;
    }
    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) {
      _showSnack('Profile not found');
      setState(() => _handled = false);
      return;
    }
    try {
      // 1) Join the game (idempotent if already joined)
      await _gameService.joinGame(gameId, user.uid, appUser.displayName);

      // 2) Fetch game details to determine park/court for automatic check-in
      final game = await _gameService.getGame(gameId);
      if (game == null) {
        _showSnack('Game not found');
        setState(() => _handled = false);
        return;
      }

      // 3) Derive court number from park data
      final park = await _parkService.getPark(game.parkId);
      if (park == null) {
        _showSnack('Park not found for game');
        setState(() => _handled = false);
        return;
      }
      final court = park.courts.firstWhere(
        (c) => c.id == game.courtId,
        orElse: () => park.courts.isNotEmpty ? park.courts.first : (throw Exception('No courts in park')),
      );
      final courtNumber = court.courtNumber;

      // 4) Ask how many players are checking in with the user
      final count = await _promptForPlayerCount();
      if (count == null) {
        setState(() => _handled = false);
        return;
      }

      // 5) Create the check-in record
      final now = DateTime.now();
      final checkIn = CheckIn(
        id: '${user.uid}_${now.millisecondsSinceEpoch}',
        userId: user.uid,
        userName: appUser.displayName,
        userPhotoUrl: appUser.photoUrl,
        parkId: game.parkId,
        parkName: game.parkName,
        courtNumber: courtNumber,
        playerCount: count,
        checkInTime: now,
        createdAt: now,
        updatedAt: now,
        // For game invites, keep defaults: isActive true, inQueue true (doesn't affect game roster)
      );
      await _checkInService.createCheckIn(checkIn);

      if (!mounted) return;
      _showSnack('Joined and checked into game at Court $courtNumber');
      Navigator.pop(context);
    } catch (e) {
      _showSnack('Failed to join: $e');
      setState(() => _handled = false);
    }
  }

  // Camera scanning removed in this build.

  Future<void> _handleCheckIn(Map<String, String> params) async {
    final user = _authService.currentUser;
    if (user == null) {
      _showSnack('Please sign in to check in');
      setState(() => _handled = false);
      return;
    }
    final appUser = await _userService.getUser(user.uid);
    if (appUser == null) {
      _showSnack('Profile not found');
      setState(() => _handled = false);
      return;
    }

    String? parkId;
    String parkName = '';
    int? courtNumber;
    String? courtId;
    bool autoQueue = (params['queue'] == '1' || params['queue'] == 'true');

    if (params['gameId'] != null) {
      final game = await _gameService.getGame(params['gameId']!);
      if (game == null) {
        _showSnack('Game not found');
        setState(() => _handled = false);
        return;
      }
      parkId = game.parkId;
      parkName = game.parkName;

      // Derive court number from park's courts if possible
      final park = await _parkService.getPark(parkId);
      if (park != null) {
        final court = park.courts.firstWhere(
          (c) => c.id == game.courtId,
          orElse: () => park.courts.isNotEmpty ? park.courts.first : (throw Exception('No courts in park')),
        );
        courtNumber = court.courtNumber;
        courtId = court.id;
      }
    } else if (params['parkId'] != null) {
      parkId = params['parkId'];
      final park = await _parkService.getPark(parkId!);
      if (park == null) {
        _showSnack('Park not found');
        setState(() => _handled = false);
        return;
      }
      parkName = park.name;
      // If QR provided a courtId, use it; else prompt for sport then court selection
      if (params['courtId'] != null && params['courtId']!.isNotEmpty) {
        final target = park.courts.firstWhere(
          (c) => c.id == params['courtId'],
          orElse: () => park.courts.isNotEmpty ? park.courts.first : (throw Exception('No courts in park')),
        );
        courtId = target.id;
        courtNumber = target.courtNumber;
        // Default to auto-queue if a specific court QR is used
        autoQueue = true;
      } else {
        // Ask for sport first (Basketball, Pickleball, Tennis)
        final sportCategory = await _promptForSportCategory(park);
        if (sportCategory == null) {
          setState(() => _handled = false);
          return;
        }

        // Filter courts by selected sport category
        final filteredCourts = _filterCourtsBySportCategory(park.courts, sportCategory);
        if (filteredCourts.isEmpty) {
          _showSnack('No courts available for the selected sport');
          setState(() => _handled = false);
          return;
        }

        // If only one court matches, select it automatically, otherwise prompt
        Court selectedCourt;
        if (filteredCourts.length == 1) {
          selectedCourt = filteredCourts.first;
        } else {
          selectedCourt = await _promptForCourtSelection(filteredCourts);
          if (selectedCourt.id.isEmpty) {
            setState(() => _handled = false);
            return;
          }
        }
        courtId = selectedCourt.id;
        courtNumber = selectedCourt.courtNumber;
        // Auto-join queue for park scans after selecting a specific court
        autoQueue = true;
      }
    }

    // Ask player count
    final count = await _promptForPlayerCount();
    if (count == null) {
      setState(() => _handled = false);
      return;
    }

    try {
      final now = DateTime.now();
      final checkIn = CheckIn(
        id: '${user.uid}_${now.millisecondsSinceEpoch}',
        userId: user.uid,
        userName: appUser.displayName,
        userPhotoUrl: appUser.photoUrl,
        parkId: parkId!,
        parkName: parkName,
        courtNumber: courtNumber ?? 1,
        playerCount: count,
        checkInTime: now,
        createdAt: now,
        updatedAt: now,
      );
      await _checkInService.createCheckIn(checkIn);

      // Auto-join the court queue if requested/implicit
      if (autoQueue && courtId != null) {
        await _cloudParkService.joinQueue(parkId, courtId, user.uid, appUser.displayName);
      }
      if (!mounted) return;
      _showSnack(autoQueue ? 'Checked in and joined queue for Court $courtNumber' : 'Checked in to $parkName');
      Navigator.pop(context);
    } catch (e) {
      _showSnack('Check-in failed: $e');
      setState(() => _handled = false);
    }
  }

  Future<_SportCategory?> _promptForSportCategory(Park park) async {
    // Only show sports that exist in the park to reduce confusion
    final hasBasketball = park.courts.any((c) => c.sportType == SportType.basketball);
    final hasPickleball = park.courts.any((c) => c.sportType == SportType.pickleballSingles || c.sportType == SportType.pickleballDoubles);
    final hasTennis = park.courts.any((c) => c.sportType == SportType.tennisSingles || c.sportType == SportType.tennisDoubles);

    final options = <_SportCategory>[];
    if (hasBasketball) options.add(_SportCategory.basketball);
    if (hasPickleball) options.add(_SportCategory.pickleball);
    if (hasTennis) options.add(_SportCategory.tennis);

    if (options.isEmpty) return null;

    _SportCategory? selected = options.first;
    return showDialog<_SportCategory>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select sport'),
        content: StatefulBuilder(
          builder: (context, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final opt in options)
                RadioListTile<_SportCategory>(
                  title: Text(_labelForSportCategory(opt)),
                  value: opt,
                  groupValue: selected,
                  onChanged: (v) => setState(() => selected = v),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, selected), child: const Text('Continue')),
        ],
      ),
    );
  }

  String _labelForSportCategory(_SportCategory c) => switch (c) {
        _SportCategory.basketball => 'Basketball',
        _SportCategory.pickleball => 'Pickleball',
        _SportCategory.tennis => 'Tennis',
      };

  List<Court> _filterCourtsBySportCategory(List<Court> courts, _SportCategory category) {
    switch (category) {
      case _SportCategory.basketball:
        return courts.where((c) => c.sportType == SportType.basketball).toList();
      case _SportCategory.pickleball:
        return courts.where((c) => c.sportType == SportType.pickleballSingles || c.sportType == SportType.pickleballDoubles).toList();
      case _SportCategory.tennis:
        return courts.where((c) => c.sportType == SportType.tennisSingles || c.sportType == SportType.tennisDoubles).toList();
    }
  }

  Future<Court> _promptForCourtSelection(List<Court> courts) async {
    // Default selection
    String selectedId = courts.first.id;
    return (await showDialog<Court>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Select court'),
            content: StatefulBuilder(
              builder: (context, setState) => DropdownButton<String>(
                value: selectedId,
                items: courts
                    .map((c) => DropdownMenuItem<String>(
                          value: c.id,
                          child: Text(c.displayName),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => selectedId = v);
                },
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(context, courts.firstWhere((c) => c.id == selectedId)),
                  child: const Text('Confirm')),
            ],
          ),
        )) ??
        Court(
          id: '',
          courtNumber: 0,
          playerCount: 0,
          lastUpdated: DateTime.now(),
        );
  }

  Future<int?> _promptForPlayerCount() async {
    int temp = 1;
    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Players with you'),
        content: StatefulBuilder(
          builder: (context, setState) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => setState(() => temp = (temp - 1).clamp(1, 10)),
              ),
              Text('$temp'),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => setState(() => temp = (temp + 1).clamp(1, 10)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, temp), child: const Text('Confirm')),
        ],
      ),
    );
  }



  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.primary),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      'Camera scanning is disabled in this build. Paste the QR text below.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_lastError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_lastError, style: TextStyle(color: theme.colorScheme.error)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: _ManualEntry(onSubmit: (value) => _handleRawValue(value)),
          )
        ],
      ),
    );
  }
}

class _ManualEntry extends StatefulWidget {
  final ValueChanged<String> onSubmit;
  const _ManualEntry({required this.onSubmit});

  @override
  State<_ManualEntry> createState() => _ManualEntryState();
}

class _ManualEntryState extends State<_ManualEntry> {
  final TextEditingController _controller = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: 'Paste QR code text',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.qr_code),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isNotEmpty) widget.onSubmit(text);
          },
          style: ElevatedButton.styleFrom(backgroundColor: theme.colorScheme.primary),
          child: const Text('Go'),
        )
      ],
    );
  }
}
