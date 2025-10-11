import 'package:flutter/material.dart';
import 'package:hoopsight/models/game_model.dart';
import 'package:hoopsight/models/checkin_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/game_service.dart';
import 'package:hoopsight/services/checkin_service.dart';
import 'package:hoopsight/services/cloud_park_service.dart';
import 'package:hoopsight/screens/game_detail_page.dart';
import 'package:hoopsight/screens/park_detail_page.dart';
import 'package:intl/intl.dart';

class MyGamesPage extends StatefulWidget {
  const MyGamesPage({super.key});

  @override
  State<MyGamesPage> createState() => _MyGamesPageState();
}

class _MyGamesPageState extends State<MyGamesPage> with SingleTickerProviderStateMixin {
  final AuthService _authService = AuthService();
  final GameService _gameService = GameService();
  final CheckInService _checkInService = CheckInService();
  final CloudParkService _cloudParkService = CloudParkService();
  
  late TabController _tabController;
  List<Game> _createdGames = [];
  List<CheckIn> _recentActivity = [];
  bool _isLoading = true;
  String? _currentUserId;
    String? _loadError; // Holds a friendly error message when one of the loads fails

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    // Begin loading
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    final user = _authService.currentUser;
    if (user == null) {
      // Not signed in: show empty state gracefully
      if (mounted) {
        setState(() {
          _createdGames = [];
          _recentActivity = [];
        });
      }
      if (mounted) {
        setState(() => _isLoading = false);
      }
      return;
    }

    _currentUserId = user.uid;

    String? errorMessage;
    debugPrint('[MyGames] Loading data for user ${_currentUserId}');

    try {
      // Load sections independently so one failure doesn't block the other
      // Created games
      try {
        await _loadCreatedGames();
      } catch (e, s) {
        debugPrint('[MyGames] Failed to load created games: $e');
        debugPrint('$s');
        errorMessage ??= 'Some sections failed to load. Pull to refresh or try again.';
      }

      // Recent activity
      try {
        await _loadRecentActivity();
      } catch (e, s) {
        debugPrint('[MyGames] Failed to load recent activity: $e');
        debugPrint('$s');
        errorMessage ??= 'Some sections failed to load. Pull to refresh or try again.';
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadError = errorMessage;
        });
      }

      if (errorMessage != null && mounted) {
        // Surface a non-blocking snackbar
        // Using addPostFrameCallback to avoid setState during build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(errorMessage!)),
          );
        });
      }
    }
  }

  Future<void> _loadCreatedGames() async {
    if (_currentUserId != null) {
      final games = await _gameService.getUserGames(_currentUserId!);
      final createdGames = games.where((game) => game.organizerId == _currentUserId).toList();
      setState(() {
        _createdGames = createdGames;
      });
    }
  }

  Future<void> _loadRecentActivity() async {
    if (_currentUserId != null) {
      final activity = await _checkInService.getUserCheckInHistory(_currentUserId!);

      // Group by park and keep the most recent check-in per park
      final Map<String, CheckIn> latestByPark = {};
      for (final c in activity) {
        final existing = latestByPark[c.parkId];
        if (existing == null || c.checkInTime.isAfter(existing.checkInTime)) {
          latestByPark[c.parkId] = c;
        }
      }

      // Sort parks by latest check-in time (newest first)
      final grouped = latestByPark.values.toList()
        ..sort((a, b) => b.checkInTime.compareTo(a.checkInTime));

      setState(() {
        _recentActivity = grouped;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Games'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'My Created Games'),
            Tab(text: 'Recent Activity'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_loadError != null) _buildErrorBanner(_loadError!),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildCreatedGamesTab(),
                      _buildRecentActivityTab(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildErrorBanner(String message) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.error.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
            TextButton(
              onPressed: _loadData,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreatedGamesTab() {
    final theme = Theme.of(context);
    
    return _createdGames.isEmpty
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.sports_basketball_outlined,
                  size: 64,
                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                ),
                const SizedBox(height: 16),
                Text(
                  'No Games Created',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Create a game to see it here',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _createdGames.length,
            itemBuilder: (context, index) {
              final game = _createdGames[index];
              return _GameCard(
                game: game,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GameDetailPage(game: game),
                    ),
                  );
                },
              );
            },
          );
  }

  Widget _buildRecentActivityTab() {
    final theme = Theme.of(context);
    
    return _recentActivity.isEmpty
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.history,
                  size: 64,
                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                ),
                const SizedBox(height: 16),
                Text(
                  'No Recent Activity',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Check in to a park to see activity here',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _recentActivity.length,
            itemBuilder: (context, index) {
              final checkIn = _recentActivity[index];
              return _ActivityCard(
                checkIn: checkIn,
                onTap: () async {
                  final park = await _cloudParkService.getPark(checkIn.parkId);
                  if (park != null) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ParkDetailPage(park: park),
                      ),
                    );
                  }
                },
              );
            },
          );
  }
}

class _GameCard extends StatelessWidget {
  final Game game;
  final VoidCallback onTap;

  const _GameCard({required this.game, required this.onTap});

  Color _getStatusColor(GameStatus status) {
    switch (status) {
      case GameStatus.scheduled:
        return Colors.blue;
      case GameStatus.active:
        return Colors.green;
      case GameStatus.completed:
        return Colors.grey;
      case GameStatus.cancelled:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // No unused formatter needed here; keep time on game schedule

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: onTap,
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
                      color: _getStatusColor(game.status).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      game.status.toString().split('.').last.toUpperCase(),
                      style: TextStyle(
                        color: _getStatusColor(game.status),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.calendar_today, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('MMM dd, yyyy • h:mm a').format(game.scheduledTime),
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.people, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    '${game.playerIds.length}/${game.maxPlayers} players',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  final CheckIn checkIn;
  final VoidCallback onTap;

  const _ActivityCard({required this.checkIn, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Show date only for check-in/out
    final dateOnly = DateFormat('MMM dd, yyyy');

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Checked in to ${checkIn.parkName}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.calendar_today, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    dateOnly.format(checkIn.checkInTime),
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
              if (checkIn.checkOutTime != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.logout, size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Checked out on ${dateOnly.format(checkIn.checkOutTime!)}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}