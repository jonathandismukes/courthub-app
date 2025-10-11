import 'package:flutter/material.dart';
import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/services/park_service.dart';
import 'package:hoopsight/services/location_service.dart';
import 'package:hoopsight/screens/landing_page.dart';
import 'package:geolocator/geolocator.dart';

class GuestHomePage extends StatefulWidget {
  const GuestHomePage({super.key});

  @override
  State<GuestHomePage> createState() => _GuestHomePageState();
}

class _GuestHomePageState extends State<GuestHomePage> {
  final ParkService _parkService = ParkService();
  final LocationService _locationService = LocationService();
  List<Park> _parks = [];
  List<Park> _filteredParks = [];
  List<ParkWithDistance> _parksWithDistance = [];
  bool _isLoading = true;
  bool _showNearby = false;
  Position? _currentPosition;
  double _radiusMiles = 25.0;
  Set<String> _selectedSportGroups = {'basketball', 'pickleball', 'tennis'};

  @override
  void initState() {
    super.initState();
    _loadParks();
  }

  Future<void> _loadParks() async {
    setState(() => _isLoading = true);
    if (_showNearby && _currentPosition != null) {
      final nearby = await _parkService.getNearbyParks(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        _radiusMiles,
      );
      setState(() {
        _parksWithDistance = nearby;
        _parks = nearby.map((p) => p.park).toList();
        _filterParks();
        _isLoading = false;
      });
    } else {
      final parks = await _parkService.getParks();
      setState(() {
        _parks = parks;
        _parksWithDistance = [];
        _filterParks();
        _isLoading = false;
      });
    }
  }

  void _filterParks() {
    if (_selectedSportGroups.isEmpty) {
      _filteredParks = _parks;
      return;
    }
    _filteredParks = _parks.where((park) {
      return park.courts.any((court) {
        final sportGroup = _getSportGroup(court.sportType);
        return _selectedSportGroups.contains(sportGroup);
      });
    }).toList();
  }

  String _getSportGroup(SportType sport) {
    switch (sport) {
      case SportType.basketball:
        return 'basketball';
      case SportType.pickleballSingles:
      case SportType.pickleballDoubles:
        return 'pickleball';
      case SportType.tennisSingles:
      case SportType.tennisDoubles:
        return 'tennis';
    }
  }

  void _toggleSportGroup(String sportGroup) {
    setState(() {
      if (_selectedSportGroups.contains(sportGroup)) {
        _selectedSportGroups.remove(sportGroup);
      } else {
        _selectedSportGroups.add(sportGroup);
      }
      _filterParks();
    });
  }

  Future<void> _toggleNearbyMode() async {
    if (!_showNearby) {
      setState(() => _isLoading = true);
      try {
        final position = await _locationService.getCurrentLocation();
        if (position != null) {
          setState(() {
            _currentPosition = position;
            _showNearby = true;
          });
          await _loadParks();
        } else {
          setState(() {
            _isLoading = false;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Unable to access location. Enable it in your browser settings.'),
                duration: const Duration(seconds: 5),
                action: SnackBarAction(
                  label: 'How?',
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Click the location icon in your browser\'s address bar and select "Allow".'),
                        duration: Duration(seconds: 8),
                      ),
                    );
                  },
                ),
              ),
            );
          }
        }
      } catch (e) {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Location error: ${e.toString().contains('denied') ? 'Access denied' : 'Try again'}'),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } else {
      setState(() => _showNearby = false);
      await _loadParks();
    }
  }

  void _showRadiusSelector() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Search Radius', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 24),
            ...[
              (10.0, '10 miles'),
              (25.0, '25 miles'),
              (50.0, '50 miles'),
              (100.0, '100 miles'),
            ].map((option) => RadioListTile<double>(
              title: Text(option.$2),
              value: option.$1,
              groupValue: _radiusMiles,
              onChanged: (value) {
                Navigator.pop(context);
                setState(() => _radiusMiles = value!);
                _loadParks();
              },
            )),
          ],
        ),
      ),
    );
  }

  void _showSignInPrompt() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign In Required'),
        content: const Text('Please sign in to view player counts, check in to courts, and access all features.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Maybe Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const LandingPage()),
              );
            },
            child: const Text('Sign In'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('CourtHub - Guest', style: TextStyle(color: theme.colorScheme.primary)),
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const LandingPage()),
              );
            },
            icon: const Icon(Icons.login),
            label: const Text('Sign In'),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SizedBox.expand(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.colorScheme.primary.withValues(alpha: 0.04),
                theme.colorScheme.secondary.withValues(alpha: 0.03),
              ],
            ),
          ),
          child: SafeArea(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: theme.colorScheme.primary))
                : RefreshIndicator(
                    onRefresh: _loadParks,
                    color: theme.colorScheme.primary,
                    child: CustomScrollView(
                      slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.info_outline, color: theme.colorScheme.primary, size: 24),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Guest Mode: View nearby parks only. Sign in to see player counts and check in.',
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                        color: theme.colorScheme.primary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                Expanded(
                                  child: _NearMeToggle(
                                    isActive: _showNearby,
                                    onTap: _toggleNearbyMode,
                                  ),
                                ),
                                if (_showNearby) ...[
                                  const SizedBox(width: 12),
                                  _RadiusButton(
                                    radiusMiles: _radiusMiles,
                                    onTap: _showRadiusSelector,
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 16),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  _SportFilterChip(
                                    sportGroup: 'basketball',
                                    isSelected: _selectedSportGroups.contains('basketball'),
                                    onTap: () => _toggleSportGroup('basketball'),
                                  ),
                                  const SizedBox(width: 10),
                                  _SportFilterChip(
                                    sportGroup: 'pickleball',
                                    isSelected: _selectedSportGroups.contains('pickleball'),
                                    onTap: () => _toggleSportGroup('pickleball'),
                                  ),
                                  const SizedBox(width: 10),
                                  _SportFilterChip(
                                    sportGroup: 'tennis',
                                    isSelected: _selectedSportGroups.contains('tennis'),
                                    onTap: () => _toggleSportGroup('tennis'),
                                  ),
                                ],
                              ),
                            ),
                            if (_showNearby && _parksWithDistance.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.location_on, size: 18, color: theme.colorScheme.primary),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Found ${_parksWithDistance.length} parks within ${_radiusMiles.toInt()} miles',
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                        color: theme.colorScheme.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final park = _filteredParks[index];
                            final distanceInfo = _showNearby && _parksWithDistance.isNotEmpty
                                ? _parksWithDistance.firstWhere(
                                    (p) => p.park.id == park.id,
                                    orElse: () => ParkWithDistance(park: park, distanceInMiles: 0),
                                  )
                                : null;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 20),
                              child: GuestParkCard(
                                park: park,
                                distanceInMiles: distanceInfo?.distanceInMiles,
                                selectedSportGroups: _selectedSportGroups,
                                onTap: _showSignInPrompt,
                              ),
                            );
                          },
                          childCount: _filteredParks.length,
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class GuestParkCard extends StatelessWidget {
  final Park park;
  final VoidCallback onTap;
  final double? distanceInMiles;
  final Set<String> selectedSportGroups;

  const GuestParkCard({super.key, required this.park, required this.onTap, this.distanceInMiles, required this.selectedSportGroups});

  String _getSportGroup(SportType sport) {
    switch (sport) {
      case SportType.basketball:
        return 'basketball';
      case SportType.pickleballSingles:
      case SportType.pickleballDoubles:
        return 'pickleball';
      case SportType.tennisSingles:
      case SportType.tennisDoubles:
        return 'tennis';
    }
  }

  String _getParkIconSport(List<Court> courts) {
    if (courts.isEmpty) return 'basketball';
    
    if (selectedSportGroups.length == 1) {
      return selectedSportGroups.first;
    }
    
    final courtsBySportGroup = <String, int>{};
    for (final court in courts) {
      final sportGroup = _getSportGroup(court.sportType);
      courtsBySportGroup[sportGroup] = (courtsBySportGroup[sportGroup] ?? 0) + 1;
    }
    
    if (courtsBySportGroup.isEmpty) return 'basketball';
    
    final mostCommonSportGroup = courtsBySportGroup.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    return mostCommonSportGroup;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filteredCourts = park.courts.where((c) => selectedSportGroups.contains(_getSportGroup(c.sportType))).toList();
    
    final courtsBySport = <SportType, int>{};
    for (final court in filteredCourts) {
      courtsBySport[court.sportType] = (courtsBySport[court.sportType] ?? 0) + 1;
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.08), width: 1),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1), width: 1),
                    ),
                    child: Center(
                      child: _getParkIconSport(filteredCourts) == 'basketball'
                          ? const Text('🏀', style: TextStyle(fontSize: 32))
                          : _getParkIconSport(filteredCourts) == 'pickleball'
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.asset('assets/images/p.jpeg', width: 32, height: 32, fit: BoxFit.contain),
                                )
                              : const Text('🎾', style: TextStyle(fontSize: 32)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(park.name, style: theme.textTheme.titleLarge),
                            ),
                            if (distanceInMiles != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.tertiary.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '${distanceInMiles!.toStringAsFixed(1)} mi',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.tertiary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.location_on, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                park.address,
                                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...courtsBySport.entries.map((entry) => _SportBadge(
                    sportType: entry.key,
                    count: entry.value,
                    theme: theme,
                  )),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_outline, size: 16, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                    const SizedBox(width: 8),
                    Text(
                      'Sign in to see player counts',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NearMeToggle extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _NearMeToggle({required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: isActive ? theme.colorScheme.primary : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.2),
            width: 2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isActive ? Icons.location_on : Icons.location_on_outlined,
              color: isActive ? Colors.white : theme.colorScheme.onSurface,
              size: 22,
            ),
            const SizedBox(width: 10),
            Text(
              isActive ? 'Near Me' : 'Show Near Me',
              style: theme.textTheme.titleMedium?.copyWith(
                color: isActive ? Colors.white : theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadiusButton extends StatelessWidget {
  final double radiusMiles;
  final VoidCallback onTap;

  const _RadiusButton({required this.radiusMiles, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.tertiary.withValues(alpha: 0.3),
            width: 2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${radiusMiles.toInt()} mi',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.tertiary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.tune, color: theme.colorScheme.tertiary, size: 20),
          ],
        ),
      ),
    );
  }
}

class _SportFilterChip extends StatelessWidget {
  final String sportGroup;
  final bool isSelected;
  final VoidCallback onTap;

  const _SportFilterChip({required this.sportGroup, required this.isSelected, required this.onTap});

  String _getSportLabel(String sportGroup) {
    switch (sportGroup) {
      case 'basketball':
        return 'Basketball';
      case 'pickleball':
        return 'Pickleball';
      case 'tennis':
        return 'Tennis';
      default:
        return sportGroup;
    }
  }

  Widget _getSportIcon(String sportGroup) {
    switch (sportGroup) {
      case 'basketball':
        return const Text('🏀', style: TextStyle(fontSize: 18));
      case 'pickleball':
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.asset('assets/images/p.jpeg', width: 18, height: 18, fit: BoxFit.contain),
        );
      case 'tennis':
        return const Text('🎾', style: TextStyle(fontSize: 18));
      default:
        return const Text('🏀', style: TextStyle(fontSize: 18));
    }
  }

  Color _getSportColor(String sportGroup) {
    switch (sportGroup) {
      case 'basketball':
        return const Color(0xFFFF8C42);
      case 'pickleball':
        return const Color(0xFF7CB342);
      case 'tennis':
        return const Color(0xFFFFD600);
      default:
        return const Color(0xFFFF8C42);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? _getSportColor(sportGroup) : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? _getSportColor(sportGroup) : theme.colorScheme.onSurface.withValues(alpha: 0.2),
            width: 2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: _getSportColor(sportGroup).withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  )
                ]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _getSportIcon(sportGroup),
            const SizedBox(width: 8),
            Text(
              _getSportLabel(sportGroup),
              style: theme.textTheme.labelLarge?.copyWith(
                color: isSelected ? Colors.white : theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SportBadge extends StatelessWidget {
  final SportType sportType;
  final int count;
  final ThemeData theme;

  const _SportBadge({required this.sportType, required this.count, required this.theme});

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

  Widget _getSportIconWidget(SportType sport) {
    switch (sport) {
      case SportType.basketball:
        return const Text('🏀', style: TextStyle(fontSize: 14));
      case SportType.pickleballSingles:
      case SportType.pickleballDoubles:
        return ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Image.asset('assets/images/p.jpeg', width: 14, height: 14, fit: BoxFit.contain),
        );
      case SportType.tennisSingles:
      case SportType.tennisDoubles:
        return const Text('🎾', style: TextStyle(fontSize: 14));
    }
  }

  String _getSportLabel(SportType sport) {
    switch (sport) {
      case SportType.basketball:
        return 'Basketball';
      case SportType.pickleballSingles:
        return 'Pickleball (Singles)';
      case SportType.pickleballDoubles:
        return 'Pickleball (Doubles)';
      case SportType.tennisSingles:
        return 'Tennis (Singles)';
      case SportType.tennisDoubles:
        return 'Tennis (Doubles)';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _getSportColor(sportType).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _getSportIconWidget(sportType),
          const SizedBox(width: 6),
          Text(
            '$count ${_getSportLabel(sportType)}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: _getSportColor(sportType),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
