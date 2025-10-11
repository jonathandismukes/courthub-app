import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlng;
import 'package:http/http.dart' as http;

import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/screens/park_detail_page.dart';
import 'package:hoopsight/services/park_service.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/location_service.dart';
import 'package:hoopsight/services/places_service.dart';
import 'package:hoopsight/config/keys.dart';

class MapPageWeb extends StatefulWidget {
  const MapPageWeb({super.key});

  @override
  State<MapPageWeb> createState() => _MapPageWebState();
}
 

class _MapPageWebState extends State<MapPageWeb> {
  final ParkService _parkService = ParkService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  // For distance calculations without requesting device location
  // (we only use math against the search center)
  // ignore: unused_field
  // Keeping as a field in case we later reuse for other helpers
  // and to stay consistent with ParkService utilities.
  // We avoid geolocation on web by policy.
  // ignore_for_file: prefer_final_fields
  // ignore_for_file: unnecessary_this
  // ignore_for_file: unused_element
  // ignore_for_file: unused_local_variable
  // ignore_for_file: unused_field
  // The analyzer pragmas above are defensive; they will be removed if noisy.
  // They do not affect runtime.
  //
  // Note: LocationService.calculateDistance returns miles.
  // We'll use it to filter parks near the search center.
  //
  // If future refactors introduce a shared distance util,
  // we can switch to that to keep DRY across app.
  //
  // You can remove the ignores above if analyzer is satisfied.
  // They are benign in stable builds.
  //
  // ignore: unused_field
  final locationService = LocationService();
  final MapController _mapController = MapController();

  StreamSubscription<List<Park>>? _parksSub;

  // Live Firestore parks (for live player counts)
  List<Park> _parks = [];
  // Google Places results near the searched location (same source as Search tab)
  List<Park> _placesParks = [];
  Park? _selectedPark;
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  latlng.LatLng? _newParkLocation;

  // Google Places service
  final PlacesService _placesService = PlacesService();

  bool _hasRunSearch = false; // markers shown only when a search has executed
  latlng.LatLng? _searchCenter; // center used to filter markers after a search
  Timer? _mapMoveDebounce; // debounce nearby lookups on pan/zoom

  static const _defaultCenter = latlng.LatLng(39.8283, -98.5795); // US center

  @override
  void initState() {
    super.initState();
    _startLiveUpdates();
    _loadInitial();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _parksSub?.cancel();
    _mapMoveDebounce?.cancel();
    super.dispose();
  }

  void _startLiveUpdates() {
    // Subscribe to Firestore parks; UI will decide when to show markers
    _parksSub = _parkService.watchParks().listen((parks) {
      if (!mounted) return;
      setState(() => _parks = parks);
    });
  }

  Future<void> _loadInitial() async {
    try {
      final parks = await _parkService.getParks();
      if (!mounted) return;
      setState(() {
        _parks = parks;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading locations: $e')),
      );
    }
  }

  bool get _showMarkers => _hasRunSearch;

  void _commitSearch() {
    final value = _searchController.text.trim();
    if (value.isNotEmpty) _searchAddress(value);
  }

  Future<void> _searchAddress(String query) async {
    if (query.isEmpty) {
      if (mounted) setState(() => _isSearching = false);
      return;
    }

    if (mounted) setState(() => _isSearching = true);
    try {
      // Guard against missing API key
      final apiKey = KeysConfig.googleApiKey;
      if (apiKey.isEmpty || apiKey.contains('REPLACE_WITH_YOUR_GOOGLE_API_KEY')) {
        if (mounted) {
          setState(() => _isSearching = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Google API key not configured. Open lib/config/keys.dart and paste your key.'),
              duration: Duration(seconds: 6),
            ),
          );
        }
        return;
      }

      final encodedQuery = Uri.encodeComponent(query);
      final googleUrl = 'https://maps.googleapis.com/maps/api/geocode/json?address=$encodedQuery&key=$apiKey';
      final proxied = Uri.parse('https://corsproxy.io/?$googleUrl');

      final response = await http.get(proxied).timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw Exception('Search timed out. Please try again.'),
          );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final status = data['status'] as String?;
        final err = data['error_message'] as String?;
        if (status != null && status != 'OK') {
          if (mounted) {
            setState(() => _isSearching = false);
            final friendly = status == 'REQUEST_DENIED'
                ? 'Google API key invalid or restricted. Check lib/config/keys.dart and API restrictions.'
                : 'No results found for this address.';
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendly)));
          }
          return;
        }
        final results = data['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          final first = results.first as Map<String, dynamic>;
          final geometry = first['geometry'] as Map<String, dynamic>;
          final location = geometry['location'] as Map<String, dynamic>;
          final target = latlng.LatLng(
            (location['lat'] as num).toDouble(),
            (location['lng'] as num).toDouble(),
          );

          if (mounted) {
            setState(() {
              _isSearching = false;
              _searchController.clear();
              _hasRunSearch = true; // enable markers once we have a search
              _searchCenter = target; // use this to filter nearby parks
            });
            _mapController.move(target, 16);
            // Fetch nearby courts (Google Places) like Search tab does
            _refreshNearbyPlaces();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Click on the map to drop a pin and add a court'),
                duration: Duration(seconds: 3),
              ),
            );
          }
        } else {
          if (mounted) {
            setState(() => _isSearching = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No results found for this address.')),
            );
          }
        }
      } else {
        if (mounted) {
          setState(() => _isSearching = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to search address. Please try again.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSearching = false);
        String message = 'Search failed. ';
        final es = e.toString();
        if (es.contains('timeout')) {
          message = 'Search timed out. Check your connection and try again.';
        } else if (es.contains('SocketException') || es.contains('Failed to fetch')) {
          message = 'Network error. Please check your connection and try again.';
        } else {
          message = 'Unable to find address. Try a different search term.';
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  Future<void> _refreshNearbyPlaces() async {
    if (!_showMarkers || _searchCenter == null) return;
    try {
      // Determine an approximate radius (meters) based on current zoom
      final zoom = _mapController.camera.zoom;
      int radiusMeters;
      if (zoom >= 17) {
        radiusMeters = 2500; // ~1.5 mi
      } else if (zoom >= 15) {
        radiusMeters = 6000; // ~3.7 mi
      } else if (zoom >= 13) {
        radiusMeters = 12000; // ~7.5 mi
      } else if (zoom >= 11) {
        radiusMeters = 30000; // ~18.6 mi
      } else {
        radiusMeters = 80000; // ~50 mi
      }

      // Query all sports and merge results by place id
      final List<Park> basketball = await _placesService.searchNearby(
        latitude: _searchCenter!.latitude,
        longitude: _searchCenter!.longitude,
        sportType: SportType.basketball,
        radius: radiusMeters,
      );
      final List<Park> pickleball = await _placesService.searchNearby(
        latitude: _searchCenter!.latitude,
        longitude: _searchCenter!.longitude,
        sportType: SportType.pickleballSingles,
        radius: radiusMeters,
      );
      final List<Park> tennis = await _placesService.searchNearby(
        latitude: _searchCenter!.latitude,
        longitude: _searchCenter!.longitude,
        sportType: SportType.tennisSingles,
        radius: radiusMeters,
      );

      final Map<String, Park> merged = {};
      void mergeList(List<Park> list) {
        for (final p in list) {
          if (merged.containsKey(p.id)) {
            final existing = merged[p.id]!;
            // Merge courts without duplicating by sport and courtNumber combination
            final existingCourtKeys = existing.courts.map((c) => '${c.sportType}-${c.courtNumber}').toSet();
            final additional = p.courts.where((c) => !existingCourtKeys.contains('${c.sportType}-${c.courtNumber}'));
            merged[p.id] = existing.copyWith(
              courts: [...existing.courts, ...additional],
            );
          } else {
            merged[p.id] = p;
          }
        }
      }

      mergeList(basketball);
      mergeList(pickleball);
      mergeList(tennis);

      if (!mounted) return;
      setState(() {
        _placesParks = merged.values.toList();
      });
    } catch (_) {
      // Ignore errors silently for map flow; search page surfaces errors explicitly
    }
  }

  // Prefer showing parks that are inside the current map viewport after a search.
  // This matches what users see instantly and avoids radius edge cases.
  bool _isInSearchArea(Park p) {
    if (!_hasRunSearch || _searchCenter == null) return false;
    try {
      final bounds = _mapController.camera.visibleBounds; // LatLngBounds
      return bounds.contains(latlng.LatLng(p.latitude, p.longitude));
    } catch (_) {
      // Fallback: if bounds are unavailable, use a generous radius by zoom
      final zoom = _mapController.camera.zoom;
      double radiusMiles;
      if (zoom >= 17) {
        radiusMiles = 6; // was 2 — too strict, show more nearby parks
      } else if (zoom >= 15) {
        radiusMiles = 10;
      } else if (zoom >= 13) {
        radiusMiles = 15;
      } else if (zoom >= 11) {
        radiusMiles = 25;
      } else if (zoom >= 9) {
        radiusMiles = 50;
      } else {
        radiusMiles = 100;
      }

      final miles = locationService.calculateDistance(
        _searchCenter!.latitude,
        _searchCenter!.longitude,
        p.latitude,
        p.longitude,
      );
      return miles <= radiusMiles;
    }
  }

  void _onMapTap(latlng.LatLng point) {
    setState(() {
      _newParkLocation = point;
    });
    _showAddParkDialog(point);
  }

  void _showAddParkDialog(latlng.LatLng point) {
    // Capture the parent Scaffold context to avoid using a dialog context after pop
    final parentContext = context;
    final nameController = TextEditingController();
    final addressController = TextEditingController();
    final cityController = TextEditingController();
    final stateController = TextEditingController();
    int basketballCourts = 0;
    int pickleballCourts = 0;
    int tennisCourts = 0;
    bool didAutofill = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (!didAutofill) {
            didAutofill = true;
            _placesService
                .reverseGeocode(latitude: point.latitude, longitude: point.longitude)
                .then((result) {
              if (result != null) {
                addressController.text = result['address'] ?? '';
                cityController.text = result['city'] ?? '';
                stateController.text = result['state'] ?? '';
                try { setDialogState(() {}); } catch (_) {}
              }
            });
          }
          final dialogTheme = Theme.of(context);
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            titlePadding: EdgeInsets.zero,
            contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            title: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    dialogTheme.colorScheme.primary,
                    dialogTheme.colorScheme.primary.withValues(alpha: 0.8),
                  ],
                ),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.add_location_alt, color: dialogTheme.colorScheme.onPrimary, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Add Court Location',
                      style: dialogTheme.textTheme.titleLarge?.copyWith(
                        color: dialogTheme.colorScheme.onPrimary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Park Name',
                      hintText: 'e.g., Lincoln Park Courts',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: addressController,
                    decoration: const InputDecoration(
                      labelText: 'Address',
                      hintText: 'e.g., 123 Main St',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: cityController,
                    decoration: const InputDecoration(
                      labelText: 'City',
                      hintText: 'e.g., Los Angeles',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: stateController,
                    decoration: const InputDecoration(
                      labelText: 'State',
                      hintText: 'e.g., California',
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Select Court Types:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(child: Text('🏀 Basketball Courts:')),
                      IconButton(
                        onPressed: () {
                          if (basketballCourts > 0) {
                            setDialogState(() => basketballCourts--);
                          }
                        },
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('$basketballCourts', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      IconButton(
                        onPressed: () => setDialogState(() => basketballCourts++),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(child: Text('🥒 Pickleball Courts:')),
                      IconButton(
                        onPressed: () {
                          if (pickleballCourts > 0) {
                            setDialogState(() => pickleballCourts--);
                          }
                        },
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('$pickleballCourts', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      IconButton(
                        onPressed: () => setDialogState(() => pickleballCourts++),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(child: Text('🎾 Tennis Courts:')),
                      IconButton(
                        onPressed: () {
                          if (tennisCourts > 0) {
                            setDialogState(() => tennisCourts--);
                          }
                        },
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('$tennisCourts', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      IconButton(
                        onPressed: () => setDialogState(() => tennisCourts++),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Location: ${( _newParkLocation?.latitude ?? point.latitude ).toStringAsFixed(4)}, ${( _newParkLocation?.longitude ?? point.longitude ).toStringAsFixed(4)}',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  setState(() {
                    _newParkLocation = null;
                  });
                },
                child: Text('Cancel', style: dialogTheme.textTheme.labelLarge),
              ),
              ElevatedButton.icon(
                onPressed: () async {
                  if (nameController.text.isEmpty || cityController.text.isEmpty || stateController.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please fill in all required fields')),
                    );
                    return;
                  }

                  final totalCourts = basketballCourts + pickleballCourts + tennisCourts;
                  if (totalCourts == 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please add at least one court')),
                    );
                    return;
                  }

                  final now = DateTime.now();
                  final courts = <Court>[];
                  int courtNumber = 1;

                  for (int i = 0; i < basketballCourts; i++) {
                    courts.add(Court(
                      id: '${DateTime.now().millisecondsSinceEpoch}-$courtNumber',
                      courtNumber: courtNumber++,
                      playerCount: 0,
                      sportType: SportType.basketball,
                      type: CourtType.fullCourt,
                      lastUpdated: now,
                    ));
                  }

                  for (int i = 0; i < pickleballCourts; i++) {
                    courts.add(Court(
                      id: '${DateTime.now().millisecondsSinceEpoch}-$courtNumber',
                      courtNumber: courtNumber++,
                      playerCount: 0,
                      sportType: SportType.pickleballDoubles,
                      type: CourtType.pickleballDoubles,
                      lastUpdated: now,
                    ));
                  }

                  for (int i = 0; i < tennisCourts; i++) {
                    courts.add(Court(
                      id: '${DateTime.now().millisecondsSinceEpoch}-$courtNumber',
                      courtNumber: courtNumber++,
                      playerCount: 0,
                      sportType: SportType.tennisSingles,
                      type: CourtType.tennisSingles,
                      lastUpdated: now,
                    ));
                  }

                  final firebaseUser = _authService.currentUser;
                  final creatorId = firebaseUser?.uid;
                  // Load full user to check admin flag
                  final appUser = firebaseUser != null ? await _userService.getUser(firebaseUser.uid) : null;
                  final creatorName = appUser?.displayName ?? firebaseUser?.email ?? 'Unknown';
                  const ownerUid = '9pUPvGV3QpTy202M09Y4ZaOU8S92';
                  final isOwner = creatorId == ownerUid;
                  final isAdmin = appUser?.isAdmin == true;
                  final autoApprove = isOwner || isAdmin;

                  final newPark = Park(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: nameController.text,
                    address: addressController.text.isEmpty ? 'Address not specified' : addressController.text,
                    city: cityController.text,
                    state: stateController.text,
                    latitude: _newParkLocation?.latitude ?? point.latitude,
                    longitude: _newParkLocation?.longitude ?? point.longitude,
                    courts: courts,
                    approved: autoApprove,
                    reviewStatus: autoApprove ? 'approved' : 'pending',
                    createdByUserId: creatorId,
                    createdByName: creatorName,
                    approvedByUserId: autoApprove ? creatorId : null,
                    approvedAt: autoApprove ? now : null,
                    reviewedByUserId: autoApprove ? creatorId : null,
                    reviewedAt: autoApprove ? now : null,
                    createdAt: now,
                    updatedAt: now,
                  );

                  Navigator.pop(context);
                  await _parkService.addPark(newPark);
                  if (!mounted) return;
                  setState(() => _newParkLocation = null);
                  // Use parent context; dialog context may be deactivated after pop
                  ScaffoldMessenger.of(parentContext).showSnackBar(
                    SnackBar(
                      content: Text(autoApprove
                          ? 'Published. Your new park is live.'
                          : "Submitted. Admin will review your park. You'll be notified once approved."),
                    ),
                  );
                },
                icon: const Icon(Icons.check_circle, size: 20),
                label: const Text('Add Location'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: dialogTheme.colorScheme.primary,
                  foregroundColor: dialogTheme.colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _zoomIn() {
    try {
      final camera = _mapController.camera;
      final nextZoom = (camera.zoom + 1.0).clamp(2.0, 19.0);
      _mapController.move(camera.center, nextZoom);
    } catch (_) {}
  }

  void _zoomOut() {
    try {
      final camera = _mapController.camera;
      final nextZoom = (camera.zoom - 1.0).clamp(2.0, 19.0);
      _mapController.move(camera.center, nextZoom);
    } catch (_) {}
  }

  int _totalPlayersAll(Park p) => p.courts.fold<int>(0, (s, c) => s + c.playerCount);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Court Locations'),
        centerTitle: true,
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primary,
                theme.colorScheme.primary.withValues(alpha: 0.8),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => _isLoading = true);
              _loadInitial();
            },
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_isLoading)
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading map...'),
                ],
              ),
            )
          else
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _defaultCenter,
                initialZoom: 4,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
                 onTap: (tapPosition, point) => _onMapTap(point),
                   // Re-query nearby places as users pan/zoom so results match viewport
                  onMapEvent: (event) {
                    if (_hasRunSearch) {
                      _mapMoveDebounce?.cancel();
                      _mapMoveDebounce = Timer(const Duration(milliseconds: 450), () {
                        _searchCenter = _mapController.camera.center;
                        _refreshNearbyPlaces();
                        if (mounted) setState(() {});
                      });
                    }
                  },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                  subdomains: const ['a', 'b', 'c'],
                  userAgentPackageName: 'com.hoopsight.app',
                  retinaMode: true,
                  maxZoom: 19,
                  // Hide noisy yellow/black error tile logs; UI uses default fallback
                  errorTileCallback: (tile, error, stackTrace) {},
                ),
                MarkerLayer(
                  markers: () {
                    final List<Marker> markers = [];
                    if (_showMarkers) {
                      final placeIds = _placesParks.map((e) => e.id).toSet();

                      // 1) Places markers (merged with live Firestore data if available)
                      for (final placePark in _placesParks.where(_isInSearchArea)) {
                        final livePark = _parks.firstWhere(
                          (p) => p.id == placePark.id,
                          orElse: () => placePark,
                        );
                        final totalPlayers = _totalPlayersAll(livePark);
                        final bool approved = livePark.approved;
                        final String status = livePark.reviewStatus;

                        markers.add(
                          Marker(
                            point: latlng.LatLng(placePark.latitude, placePark.longitude),
                            width: 46,
                            height: 46,
                            alignment: Alignment.center,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => _selectedPark = livePark),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.15),
                                          blurRadius: 8,
                                          offset: const Offset(0, 3),
                                        )
                                      ],
                                    ),
                                    child: Icon(Icons.location_on, color: theme.colorScheme.onPrimary, size: 20),
                                  ),
                                  // Player count badge (top-right)
                                  Positioned(
                                    right: -8,
                                    top: -6,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.secondary,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '$totalPlayers',
                                        style: TextStyle(
                                          color: theme.colorScheme.onSecondary,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Status badge (bottom-left)
                                  Positioned(
                                    left: -8,
                                    bottom: -6,
                                    child: Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: approved
                                            ? Colors.green
                                            : (status == 'denied' ? Colors.red : Colors.orange),
                                        shape: BoxShape.circle,
                                        border: Border.all(color: Colors.white, width: 2),
                                      ),
                                      child: Icon(
                                        approved
                                            ? Icons.check
                                            : (status == 'denied' ? Icons.block : Icons.hourglass_empty),
                                        size: 12,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }

                      // 2) Firestore-only markers (parks not returned by Google Places)
                      for (final p in _parks.where(_isInSearchArea)) {
                        if (placeIds.contains(p.id)) continue;
                        final totalPlayers = _totalPlayersAll(p);
                        final bool approved = p.approved;
                        final String status = p.reviewStatus;
                        markers.add(
                          Marker(
                            point: latlng.LatLng(p.latitude, p.longitude),
                            width: 46,
                            height: 46,
                            alignment: Alignment.center,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => _selectedPark = p),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.15),
                                          blurRadius: 8,
                                          offset: const Offset(0, 3),
                                        )
                                      ],
                                    ),
                                    child: Icon(Icons.location_on, color: theme.colorScheme.onPrimary, size: 20),
                                  ),
                                  Positioned(
                                    right: -8,
                                    top: -6,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.secondary,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '$totalPlayers',
                                        style: TextStyle(
                                          color: theme.colorScheme.onSecondary,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: -8,
                                    bottom: -6,
                                    child: Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: approved
                                            ? Colors.green
                                            : (status == 'denied' ? Colors.red : Colors.orange),
                                        shape: BoxShape.circle,
                                        border: Border.all(color: Colors.white, width: 2),
                                      ),
                                      child: Icon(
                                        approved
                                            ? Icons.check
                                            : (status == 'denied' ? Icons.block : Icons.hourglass_empty),
                                        size: 12,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }
                    }

                    if (_newParkLocation != null) {
                      markers.add(
                        Marker(
                          point: _newParkLocation!,
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.15),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                )
                              ],
                            ),
                            child: const Icon(Icons.location_on, color: Colors.white, size: 20),
                          ),
                        ),
                      );
                    }

                    return markers;
                  }(),
                ),
              ],
            ),

          // Top overlay: search bar only
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16,
            right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Address search bar
                Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search, color: theme.colorScheme.primary, size: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                               hintText: 'Search a city or address...',
                              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            textInputAction: TextInputAction.search,
                            onEditingComplete: _commitSearch,
                            onSubmitted: (value) {
                              if (value.isNotEmpty) _searchAddress(value);
                            },
                          ),
                        ),
                        if (_searchController.text.isNotEmpty)
                          IconButton(
                            icon: Icon(Icons.clear, size: 20, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                            onPressed: () {
                              _searchController.clear();
                              if (mounted) setState(() => _isSearching = false);
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_isSearching)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text('Finding location...'),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          if (_selectedPark != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: _SelectedParkCard(
                park: _selectedPark!,
                onClose: () => setState(() => _selectedPark = null),
              ),
            ),

          // Zoom controls (web only overlay)
          Positioned(
            right: 16,
            bottom: _selectedPark != null ? 180 : 24,
            child: _ZoomControls(
              onZoomIn: _zoomIn,
              onZoomOut: _zoomOut,
            ),
          ),

          // Find me on bottom-left (opposite the zoom controls)
          Positioned(
            left: 16,
            bottom: 24,
            child: FloatingActionButton(
              heroTag: 'my_location_web',
              onPressed: () async {
                try {
                  final pos = await LocationService().getCurrentLocation();
                  if (pos != null && mounted) {
                    final target = latlng.LatLng(pos.latitude, pos.longitude);
                    _mapController.move(target, 15);
                  } else if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Unable to access location. Enable location in your browser settings.')),
                    );
                  }
                } catch (_) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Location access denied. Please enable it in your browser.')),
                    );
                  }
                }
              },
              backgroundColor: Theme.of(context).colorScheme.surface,
              child: Icon(Icons.my_location, color: Theme.of(context).colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectedParkCard extends StatelessWidget {
  const _SelectedParkCard({required this.park, required this.onClose});
  final Park park;
  final VoidCallback onClose;

  int get _totalPlayers => park.courts.fold(0, (sum, c) => sum + c.playerCount);
  int get _basketball => park.courts.where((c) => c.sportType == SportType.basketball).length;
  int get _pickleball => park.courts.where((c) => c.sportType == SportType.pickleballDoubles || c.sportType == SportType.pickleballSingles).length;
  int get _tennis => park.courts.where((c) => c.sportType == SportType.tennisSingles || c.sportType == SportType.tennisDoubles).length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  theme.colorScheme.primary,
                  theme.colorScheme.primary.withValues(alpha: 0.7),
                ]),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.location_on, color: theme.colorScheme.onPrimary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          park.name,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: onClose,
                        tooltip: 'Close',
                      )
                    ],
                  ),
                  Text(
                    '${park.city}, ${park.state}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Use Wrap to avoid horizontal overflow in narrow layouts
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _StatChip(icon: Icons.sports_basketball, label: 'Basketball', count: _basketball),
                          _StatChip(icon: Icons.sports_tennis, label: 'Pickleball', count: _pickleball),
                          _StatChip(icon: Icons.sports, label: 'Tennis', count: _tennis),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.people, size: 16, color: theme.colorScheme.primary),
                            const SizedBox(width: 4),
                            Text(
                              '$_totalPlayers active',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Use Wrap so action buttons flow to next line on narrow widths
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => ParkDetailPage(park: park)),
                          );
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        icon: const Icon(Icons.info_outline, size: 18),
                        label: const Text('View Details'),
                      ),
                    ],
                  )
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({required this.onZoomIn, required this.onZoomOut});

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 6,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Zoom in',
              onPressed: onZoomIn,
              icon: Icon(Icons.add, color: theme.colorScheme.primary),
            ),
            Container(
              height: 1,
              width: 40,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
            ),
            IconButton(
              tooltip: 'Zoom out',
              onPressed: onZoomOut,
              icon: Icon(Icons.remove, color: theme.colorScheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label, required this.count});

  final IconData icon;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text('$count', style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
          const SizedBox(width: 4),
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
        ],
      ),
    );
  }
}
