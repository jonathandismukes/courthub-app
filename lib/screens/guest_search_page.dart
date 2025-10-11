import 'package:flutter/material.dart';
import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/services/places_service.dart';
import 'package:hoopsight/screens/landing_page.dart';

class GuestSearchPage extends StatefulWidget {
  const GuestSearchPage({super.key});

  @override
  State<GuestSearchPage> createState() => _GuestSearchPageState();
}

class _GuestSearchPageState extends State<GuestSearchPage> {
  final PlacesService _placesService = PlacesService();
  final TextEditingController _stateController = TextEditingController();
  final TextEditingController _cityController = TextEditingController();
  List<Park> _searchResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  String _selectedSport = 'basketball';

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

    setState(() {
      _isSearching = true;
      _hasSearched = false;
    });

    try {
      SportType sportType;
      switch (_selectedSport) {
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
          sportType = SportType.basketball;
      }
      
      final results = await _placesService.searchCourts(
        city: city.isEmpty ? state : city,
        state: state.isEmpty ? city : state,
        sportType: sportType,
      );

      setState(() {
        _searchResults = results;
        _isSearching = false;
        _hasSearched = true;
      });

      if (results.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No $_selectedSport courts found. Try different location.')),
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

  void _showSignInPrompt() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign In Required'),
        content: const Text('Please sign in to view full park details, player counts, and check in to courts.'),
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
        title: Text('Search - Guest', style: TextStyle(color: theme.colorScheme.primary)),
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
            child: Column(
              children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
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
                        Icon(Icons.info_outline, color: theme.colorScheme.primary, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Guest Mode: Search only. Sign in for full access.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Select Sport',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
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
                          isSelected: _selectedSport == 'basketball',
                          onTap: () => setState(() => _selectedSport = 'basketball'),
                        ),
                        const SizedBox(width: 10),
                        _SportSelectorChip(
                          sportType: SportType.pickleballSingles,
                          label: 'Pickleball',
                          icon: '🏓',
                          isSelected: _selectedSport == 'pickleball',
                          onTap: () => setState(() => _selectedSport = 'pickleball'),
                        ),
                        const SizedBox(width: 10),
                        _SportSelectorChip(
                          sportType: SportType.tennisSingles,
                          label: 'Tennis',
                          icon: '🎾',
                          isSelected: _selectedSport == 'tennis',
                          onTap: () => setState(() => _selectedSport = 'tennis'),
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
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.search, color: Colors.white),
                      label: Text(
                        _isSearching ? 'Searching...' : 'Search',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
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
                  child: _buildResults(theme),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (!_hasSearched) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _selectedSport == 'basketball'
                ? const Text('🏀', style: TextStyle(fontSize: 80))
                : _selectedSport == 'pickleball'
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.asset('assets/images/p.jpeg', width: 80, height: 80, fit: BoxFit.contain),
                      )
                    : const Text('🎾', style: TextStyle(fontSize: 80)),
            const SizedBox(height: 20),
            Text(
              'Search ${_selectedSport[0].toUpperCase()}${_selectedSport.substring(1)} Courts',
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'Select a sport, enter a city and state, then tap "Search"',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }
    if (_searchResults.isEmpty) {
      return Center(
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
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: _GuestSearchParkCard(
          park: _searchResults[index],
          onTap: _showSignInPrompt,
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

class _GuestSearchParkCard extends StatelessWidget {
  final Park park;
  final VoidCallback onTap;

  const _GuestSearchParkCard({required this.park, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sportType = park.courts.isNotEmpty ? park.courts.first.sportType : SportType.basketball;

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
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1), width: 1),
                    ),
                    child: Center(
                      child: sportType == SportType.basketball
                          ? const Text('🏀', style: TextStyle(fontSize: 24))
                          : (sportType == SportType.pickleballSingles || sportType == SportType.pickleballDoubles)
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
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.lock_outline, size: 14, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                          const SizedBox(width: 6),
                          Text(
                            'Sign in for details',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                              fontWeight: FontWeight.w500,
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
    
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? _getSportColor(sportType) : theme.colorScheme.surface,
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            label == 'Pickleball'
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.asset('assets/images/p.jpeg', width: 20, height: 20, fit: BoxFit.contain),
                  )
                : Text(icon, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
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
    );
  }
}
