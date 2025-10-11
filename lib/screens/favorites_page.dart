import 'package:flutter/material.dart';
import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/cloud_park_service.dart';
import 'package:hoopsight/screens/park_detail_page.dart';

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final CloudParkService _parkService = CloudParkService();
  
  List<Park> _favoriteParks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final firebaseUser = _authService.currentUser;
    if (firebaseUser != null) {
      final user = await _userService.getUser(firebaseUser.uid);
      if (user != null) {
        final parks = <Park>[];
        for (final parkId in user.favoriteParkIds) {
          final park = await _parkService.getPark(parkId);
          if (park != null) {
            parks.add(park);
          }
        }
        setState(() {
          _favoriteParks = parks;
          _isLoading = false;
        });
      }
    } else {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Favorite Parks'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _favoriteParks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.favorite_border,
                        size: 64,
                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No Favorites Yet',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap the heart icon on any park to add it here',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _favoriteParks.length,
                  itemBuilder: (context, index) {
                    final park = _favoriteParks[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 16),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: theme.colorScheme.primary,
                          child: const Icon(Icons.sports_basketball, color: Colors.white),
                        ),
                        title: Text(park.name),
                        subtitle: Text('${park.city}, ${park.state}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ParkDetailPage(park: park),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
    );
  }
}
