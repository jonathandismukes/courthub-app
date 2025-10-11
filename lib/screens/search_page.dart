import 'package:flutter/material.dart';
import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/services/park_service.dart';
import 'package:hoopsight/services/places_service.dart';
import 'package:hoopsight/screens/park_detail_page.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/config/keys.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final ParkService _parkService = ParkService();
  final PlacesService _placesService = PlacesService();
  final TextEditingController _stateController = TextEditingController();
  final TextEditingController _cityController = TextEditingController();
  List<Park> _searchResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  Set<String> _selectedSports = {'basketball'};

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _stateController.dispose();
    _cityController.dispose();
    super.dispose();
  }

  Future<void> _searchPlaces() async {
    final city = _cityController.text.trim();
    final state = _stateController.text.trim();

    if (city.isEmpty && state.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a city or state to search')),
      );
      return;
    }

    // Early guard for missing API key
    final apiKey = KeysConfig.googleApiKey;
    if (apiKey.isEmpty || apiKey.contains('REPLACE_WITH_YOUR_GOOGLE_API_KEY')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Google API key not configured. Open lib/config/keys.dart and paste your key.'),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }

    setState(() {
      _isSearching = true;
      _hasSearched = false;
    });

    try {
      List<Park> allResults = [];
      
      // Search for each selected sport
      for (final sport in _selectedSports) {
        SportType sportType;
        switch (sport) {
          case 'basketball':
            sportType = SportType.basketball;
            break;
          case 'pickleball':
            sportType = SportType.pickleballSingles;
            break;
          case 'tennis':
            sportType = SportType.tennisSingles;
            break;
          default:
            continue;
        }
        
        final results = await _placesService.searchCourts(
          city: city.isEmpty ? state : city,
          state: state.isEmpty ? city : state,
          sportType: sportType,
        );
        
        allResults.addAll(results);
      }
      
      // Merge parks with same ID (combine courts from different sport searches)
      final uniqueParks = <String, Park>{};
      for (final park in allResults) {
        if (uniqueParks.containsKey(park.id)) {
          // Park already exists - merge courts
          final existingPark = uniqueParks[park.id]!;
          final combinedCourts = List<Court>.from(existingPark.courts);
          
          // Add courts from new park that don't duplicate sport types
          for (final newCourt in park.courts) {
            final hasSameSportType = combinedCourts.any((c) => c.sportType == newCourt.sportType);
            if (!hasSameSportType) {
              combinedCourts.add(Court(
                id: '${park.id}-${combinedCourts.length + 1}',
                courtNumber: combinedCourts.length + 1,
                playerCount: 0,
                sportType: newCourt.sportType,
                lastUpdated: newCourt.lastUpdated,
              ));
            }
          }
          
          // Update park with merged courts
          uniqueParks[park.id] = existingPark.copyWith(courts: combinedCourts);
        } else {
          uniqueParks[park.id] = park;
        }
      }

      setState(() {
        _searchResults = uniqueParks.values.toList();
        _isSearching = false;
        _hasSearched = true;
      });

      if (uniqueParks.isEmpty && mounted) {
        final sportText = _selectedSports.length == 1 
            ? _selectedSports.first 
            : '${_selectedSports.length} sports';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No $sportText courts found. Try different location.')),
        );
      }
    } catch (e) {
      setState(() {
        _isSearching = false;
        _hasSearched = true;
      });
      if (mounted) {
        String errorMessage = 'Search failed. ';
        if (e.toString().contains('timeout')) {
          errorMessage += 'Request timed out. Check your internet connection.';
        } else if (e.toString().contains('GOOGLE_API_KEY_MISSING')) {
          errorMessage = 'Google API key not configured. Open lib/config/keys.dart and paste your key.';
        } else if (e.toString().contains('GOOGLE_API_REQUEST_DENIED')) {
          errorMessage = 'Google API key invalid or restricted. Verify the key and API restrictions in Google Cloud.';
        } else if (e.toString().contains('Failed to fetch') || e.toString().contains('SocketException')) {
          errorMessage += 'Network error. Please check your connection and try again.';
        } else {
          errorMessage += 'Please try again later.';
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: _searchPlaces,
            ),
          ),
        );
      }
    }
  }

  void _clearSearch() {
    _stateController.clear();
    _cityController.clear();
    setState(() {
      _searchResults = [];
      _hasSearched = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.search, color: theme.colorScheme.primary, size: 32),
                            const SizedBox(width: 12),
                            Text('Search Parks', style: theme.textTheme.headlineMedium?.copyWith(color: theme.colorScheme.primary)),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Select Sports (${_selectedSports.length})',
                              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                            ),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  if (_selectedSports.length == 3) {
                                    _selectedSports = {'basketball'};
                                  } else {
                                    _selectedSports = {'basketball', 'pickleball', 'tennis'};
                                  }
                                });
                              },
                              child: Text(
                                _selectedSports.length == 3 ? 'Clear All' : 'Select All',
                                style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _SportSelectorChip(
                                sportType: SportType.basketball,
                                label: 'Basketball',
                                icon: '🏀',
                                isSelected: _selectedSports.contains('basketball'),
                                onTap: () {
                                  setState(() {
                                    if (_selectedSports.contains('basketball')) {
                                      if (_selectedSports.length > 1) {
                                        _selectedSports.remove('basketball');
                                      }
                                    } else {
                                      _selectedSports.add('basketball');
                                    }
                                  });
                                },
                              ),
                              const SizedBox(width: 10),
                              _SportSelectorChip(
                                sportType: SportType.pickleballSingles,
                                label: 'Pickleball',
                                icon: '🏓',
                                isSelected: _selectedSports.contains('pickleball'),
                                onTap: () {
                                  setState(() {
                                    if (_selectedSports.contains('pickleball')) {
                                      if (_selectedSports.length > 1) {
                                        _selectedSports.remove('pickleball');
                                      }
                                    } else {
                                      _selectedSports.add('pickleball');
                                    }
                                  });
                                },
                              ),
                              const SizedBox(width: 10),
                              _SportSelectorChip(
                                sportType: SportType.tennisSingles,
                                label: 'Tennis',
                                icon: '🎾',
                                isSelected: _selectedSports.contains('tennis'),
                                onTap: () {
                                  setState(() {
                                    if (_selectedSports.contains('tennis')) {
                                      if (_selectedSports.length > 1) {
                                        _selectedSports.remove('tennis');
                                      }
                                    } else {
                                      _selectedSports.add('tennis');
                                    }
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: _SearchTextField(
                                controller: _stateController,
                                label: 'State',
                                hint: 'e.g., California',
                                icon: Icons.map,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _SearchTextField(
                                controller: _cityController,
                                label: 'City',
                                hint: 'e.g., Los Angeles',
                                icon: Icons.location_city,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _isSearching ? null : _searchPlaces,
                            icon: _isSearching
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(Icons.search, color: Colors.white),
                            label: Text(
                              _isSearching ? 'Searching...' : 'Search',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: theme.colorScheme.primary,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        if (_hasSearched) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: _clearSearch,
                                icon: Icon(Icons.clear, size: 18, color: theme.colorScheme.primary),
                                label: Text('Clear Search', style: TextStyle(color: theme.colorScheme.primary)),
                              ),
                              const Spacer(),
                              Text(
                                '${_searchResults.length} court${_searchResults.length != 1 ? 's' : ''} found',
                                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  Expanded(
                    child: !_hasSearched
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _selectedSports.length == 1
                                    ? (_selectedSports.first == 'basketball'
                                        ? const Text('🏀', style: TextStyle(fontSize: 80))
                                        : _selectedSports.first == 'pickleball'
                                            ? ClipRRect(
                                                borderRadius: BorderRadius.circular(12),
                                                child: Image.asset('assets/images/p.jpeg', width: 80, height: 80, fit: BoxFit.contain),
                                              )
                                            : const Text('🎾', style: TextStyle(fontSize: 80)))
                                    : Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (_selectedSports.contains('basketball')) const Text('🏀', style: TextStyle(fontSize: 50)),
                                          if (_selectedSports.contains('basketball') && (_selectedSports.contains('pickleball') || _selectedSports.contains('tennis'))) const SizedBox(width: 12),
                                          if (_selectedSports.contains('pickleball'))
                                            ClipRRect(
                                              borderRadius: BorderRadius.circular(8),
                                              child: Image.asset('assets/images/p.jpeg', width: 50, height: 50, fit: BoxFit.contain),
                                            ),
                                          if (_selectedSports.contains('pickleball') && _selectedSports.contains('tennis')) const SizedBox(width: 12),
                                          if (_selectedSports.contains('tennis')) const Text('🎾', style: TextStyle(fontSize: 50)),
                                        ],
                                      ),
                                const SizedBox(height: 20),
                                Text(
                                  _selectedSports.length == 1
                                      ? 'Search ${_selectedSports.first[0].toUpperCase()}${_selectedSports.first.substring(1)} Courts'
                                      : 'Search ${_selectedSports.length} Sports',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 40),
                                  child: Text(
                                    'Select one or more sports, enter a city and state, then tap "Search"',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : _searchResults.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.park_outlined, size: 64, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                                    const SizedBox(height: 16),
                                    Text(
                                      'No courts found',
                                      style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Try searching a different location',
                                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                                itemCount: _searchResults.length,
                                itemBuilder: (context, index) => Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: _SearchParkCard(
                                    park: _searchResults[index],
                                    onTap: () async {
                                      final selectedPark = _searchResults[index];
                                      // Attribute creator and auto-approve if owner/admin
                                      final auth = AuthService();
                                      final users = UserService();
                                      final firebaseUser = auth.currentUser;
                                      final creatorId = firebaseUser?.uid;
                                      final appUser = firebaseUser != null ? await users.getUser(firebaseUser.uid) : null;
                                      final creatorName = appUser?.displayName ?? firebaseUser?.email ?? 'Unknown';
                                      const ownerUid = '9pUPvGV3QpTy202M09Y4ZaOU8S92';
                                      final isOwner = creatorId == ownerUid;
                                      final isAdmin = appUser?.isAdmin == true;
                                      final autoApprove = isOwner || isAdmin;

                                      final pendingPark = selectedPark.copyWith(
                                        approved: autoApprove,
                                        reviewStatus: autoApprove ? 'approved' : 'pending',
                                        approvedByUserId: autoApprove ? creatorId : null,
                                        approvedAt: autoApprove ? DateTime.now() : null,
                                        reviewedByUserId: autoApprove ? creatorId : null,
                                        reviewedAt: autoApprove ? DateTime.now() : null,
                                        createdByUserId: creatorId,
                                        createdByName: creatorName,
                                        updatedAt: DateTime.now(),
                                      );

                                      await _parkService.addPark(pendingPark);
                                      if (mounted) {
                                        await Navigator.push(
                                          context,
                                          MaterialPageRoute(builder: (_) => ParkDetailPage(park: pendingPark)),
                                        );
                                      }
                                    },
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

class _SearchTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;

  const _SearchTextField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, color: theme.colorScheme.primary),
        filled: true,
        fillColor: theme.colorScheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: theme.colorScheme.onSurface.withValues(alpha: 0.12)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: theme.colorScheme.onSurface.withValues(alpha: 0.12)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
        ),
      ),
    );
  }
}

class _SearchParkCard extends StatelessWidget {
  final Park park;
  final VoidCallback onTap;

  const _SearchParkCard({required this.park, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalPlayers = park.courts.fold(0, (sum, court) => sum + court.playerCount);
    final availableCourts = park.courts.where((c) => c.playerCount < getMaxPlayersForSport(c.sportType)).length;
    
    // Get unique sport types in this park
    final uniqueSportTypes = park.courts.map((c) => c.sportType).toSet().toList();
    final hasMultipleSports = uniqueSportTypes.length > 1;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.08)),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Show multiple sport icons if park has multiple court types
                  if (hasMultipleSports)
                    Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1), width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: uniqueSportTypes.map((sport) {
                          Widget icon;
                          if (sport == SportType.basketball) {
                            icon = const Text('🏀', style: TextStyle(fontSize: 20));
                          } else if (sport == SportType.pickleballSingles || sport == SportType.pickleballDoubles) {
                            icon = ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.asset('assets/images/p.jpeg', width: 20, height: 20, fit: BoxFit.contain),
                            );
                          } else {
                            icon = const Text('🎾', style: TextStyle(fontSize: 20));
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: icon,
                          );
                        }).toList(),
                      ),
                    )
                  else
                    // Single sport icon
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1), width: 1),
                      ),
                      child: Center(
                        child: uniqueSportTypes.first == SportType.basketball
                            ? const Text('🏀', style: TextStyle(fontSize: 24))
                            : (uniqueSportTypes.first == SportType.pickleballSingles || uniqueSportTypes.first == SportType.pickleballDoubles)
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: Image.asset('assets/images/p.jpeg', width: 24, height: 24, fit: BoxFit.contain),
                                  )
                                : const Text('🎾', style: TextStyle(fontSize: 24)),
                      ),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(park.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(
                          '${park.city}, ${park.state}',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _CompactStatBadge(
                    icon: Icons.grid_view,
                    label: '${park.courts.length}',
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  _CompactStatBadge(
                    icon: Icons.people,
                    label: '$totalPlayers',
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: availableCourts > 0 ? theme.colorScheme.tertiary.withValues(alpha: 0.1) : theme.colorScheme.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            availableCourts > 0 ? Icons.check_circle : Icons.cancel,
                            size: 16,
                            color: availableCourts > 0 ? theme.colorScheme.tertiary : theme.colorScheme.error,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            availableCourts > 0 ? '$availableCourts Open' : 'Full',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: availableCourts > 0 ? theme.colorScheme.tertiary : theme.colorScheme.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
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
}

class _CompactStatBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _CompactStatBadge({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SportSelectorChip extends StatelessWidget {
  final SportType sportType;
  final String label;
  final String icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _SportSelectorChip({
    required this.sportType,
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  Color _getSportColor(SportType sport) {
    switch (sport) {
      case SportType.basketball:
        return const Color(0xFFFF8C42);
      case SportType.pickleballSingles:
      case SportType.pickleballDoubles:
        return const Color(0xFF7CB342);
      case SportType.tennisSingles:
      case SportType.tennisDoubles:
        return const Color(0xFFFFD600);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool hasBackgroundImage = (label == 'Basketball' || label == 'Pickleball' || label == 'Tennis') && isSelected;
    
    String? backgroundImagePath;
    if (hasBackgroundImage) {
      if (label == 'Basketball') {
        backgroundImagePath = 'assets/images/basketball_court.jpeg';
      } else if (label == 'Pickleball') {
        backgroundImagePath = 'assets/images/pickleball.jpeg';
      } else if (label == 'Tennis') {
        backgroundImagePath = 'assets/images/Image_10-6-25_at_3.57_AM.jpeg';
      }
    }
    
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: hasBackgroundImage ? Colors.transparent : (isSelected ? _getSportColor(sportType) : theme.colorScheme.surface),
          image: hasBackgroundImage && backgroundImagePath != null
              ? DecorationImage(
                  image: AssetImage(backgroundImagePath),
                  fit: BoxFit.cover,
                  opacity: 0.7,
                )
              : null,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? _getSportColor(sportType) : theme.colorScheme.onSurface.withValues(alpha: 0.2),
            width: 2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: _getSportColor(sportType).withValues(alpha: 0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  )
                ]
              : [],
        ),
        child: Container(
          decoration: hasBackgroundImage
              ? BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                )
              : null,
          padding: hasBackgroundImage ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4) : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (label != 'Tennis' || !isSelected)
                label == 'Pickleball'
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.asset('assets/images/p.jpeg', width: 20, height: 20, fit: BoxFit.contain),
                      )
                    : Text(icon, style: const TextStyle(fontSize: 20)),
              if (label != 'Tennis' || !isSelected) const SizedBox(width: 10),
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: isSelected ? Colors.white : theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
