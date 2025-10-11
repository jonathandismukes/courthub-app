import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/screens/park_detail_page.dart';
import 'package:hoopsight/services/park_service.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/location_service.dart';
import 'package:hoopsight/services/places_service.dart';
import 'package:hoopsight/config/keys.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final ParkService _parkService = ParkService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  LatLng? _newParkLocation;
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  Park? _selectedPark;

  // Live Firestore parks for real-time player counts
  StreamSubscription<List<Park>>? _parksSub;
  List<Park> _parks = [];

  // Google Places merged results around the search center
  final PlacesService _placesService = PlacesService();
  List<Park> _placesParks = [];
  bool _hasRunSearch = false; // gates markers until a search runs
  LatLng? _searchCenter; // anchor for nearby searches
  LatLngBounds? _visibleBounds; // for viewport filtering
  Timer? _mapMoveDebounce; // debounce re-query on pan/zoom

  // Cache for marker badge icons keyed by total player count
  final Map<int, BitmapDescriptor> _badgeIconCache = {};

  @override
  void initState() {
    super.initState();
    _startLiveUpdates();
    _loadParks();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _mapController?.dispose();
    _mapMoveDebounce?.cancel();
    _parksSub?.cancel();
    super.dispose();
  }

  Future<void> _loadParks() async {
    final parks = await _parkService.getParks();
    setState(() {
      _parks = parks;
    });
  }

  int _getTotalPlayers(Park park) => park.courts.fold(0, (sum, court) => sum + court.playerCount);

  void _startLiveUpdates() {
    _parksSub = _parkService.watchParks().listen((parks) {
      if (!mounted) return;
      setState(() => _parks = parks);
      if (_hasRunSearch) _rebuildMarkers();
    });
  }

  Future<void> _searchAddress(String query) async {
    if (query.isEmpty) {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() => _isSearching = true);
    }

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
      final url = 'https://maps.googleapis.com/maps/api/geocode/json?address=$encodedQuery&key=$apiKey';
      
      debugPrint('🔍 Searching address: $query');
      
      final response = await http.get(
        Uri.parse(url),
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw Exception('Search timed out. Please try again.');
        },
      );
      
      debugPrint('📊 Response status: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final status = data['status'] as String?;
        final errorMessage = data['error_message'] as String?;
        if (status != null && status != 'OK') {
          debugPrint('❌ Geocode status: $status | $errorMessage');
          if (mounted) {
            setState(() => _isSearching = false);
            final friendly =
                status == 'REQUEST_DENIED' ? 'Google API key invalid or restricted. Check lib/config/keys.dart and Google Cloud restrictions.' : 'No results found for this address.';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(friendly)),
            );
          }
          return;
        }
        final results = data['results'] as List<dynamic>?;
        
        debugPrint('📍 Results found: ${results?.length ?? 0}');
        
        if (mounted && results != null && results.isNotEmpty) {
          final firstResult = results.first;
          final geometry = firstResult['geometry'];
          final location = geometry['location'];
          final latLng = LatLng(
            location['lat'].toDouble(),
            location['lng'].toDouble(),
          );
          
          debugPrint('✅ Moving to location: ${latLng.latitude}, ${latLng.longitude}');
          
          setState(() {
            _isSearching = false;
            _searchController.clear();
            _hasRunSearch = true;
            _searchCenter = latLng;
          });
          
          _mapController?.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(target: latLng, zoom: 16),
            ),
          );
          await _refreshNearbyPlaces();
          if (mounted) _rebuildMarkers();
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Tap on the map to drop a pin and add a court'),
                duration: Duration(seconds: 3),
              ),
            );
          }
        } else if (mounted) {
          debugPrint('❌ No results found');
          setState(() {
            _isSearching = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No results found for this address.')),
          );
        }
      } else if (mounted) {
        debugPrint('❌ HTTP error: ${response.statusCode}');
        setState(() {
          _isSearching = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to search address. Please try again.')),
        );
      }
    } catch (e) {
      debugPrint('❌ Geocoding error: $e');
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
        
        String errorMessage = 'Search failed. ';
        if (e.toString().contains('timeout')) {
          errorMessage = 'Search timed out. Check your internet connection and try again.';
        } else if (e.toString().contains('SocketException') || e.toString().contains('Failed to fetch')) {
          errorMessage = 'Network error. Please check your connection and try again.';
        } else {
          errorMessage = 'Unable to find address. Try a different search term.';
        }
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _searchAddress(query),
            ),
          ),
        );
      }
    }
  }

  Future<void> _refreshNearbyPlaces() async {
    if (!_hasRunSearch || _searchCenter == null) return;
    try {
      // approximate radius based on current zoom
      final zoomFuture = _mapController?.getZoomLevel();
      double zoom = 15;
      if (zoomFuture != null) {
        try { zoom = await zoomFuture; } catch (_) {}
      }
      int radiusMeters;
      if (zoom >= 17) {
        radiusMeters = 2500;
      } else if (zoom >= 15) {
        radiusMeters = 6000;
      } else if (zoom >= 13) {
        radiusMeters = 12000;
      } else if (zoom >= 11) {
        radiusMeters = 30000;
      } else {
        radiusMeters = 80000;
      }

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
      // silently ignore errors for map flow
    }
  }

  bool _isInSearchArea(Park p) {
    if (!_hasRunSearch || _searchCenter == null) return false;
    if (_visibleBounds != null) {
      final b = _visibleBounds!;
      final LatLng pos = LatLng(p.latitude, p.longitude);
      final withinLat = (pos.latitude >= b.southwest.latitude && pos.latitude <= b.northeast.latitude) ||
          (b.northeast.latitude < b.southwest.latitude &&
              (pos.latitude >= b.southwest.latitude || pos.latitude <= b.northeast.latitude));
      final withinLng = (pos.longitude >= b.southwest.longitude && pos.longitude <= b.northeast.longitude) ||
          (b.northeast.longitude < b.southwest.longitude &&
              (pos.longitude >= b.southwest.longitude || pos.longitude <= b.northeast.longitude));
      return withinLat && withinLng;
    }
    return true; // fallback if bounds unavailable
  }

  Future<void> _updateVisibleRegion() async {
    try {
      final bounds = await _mapController?.getVisibleRegion();
      if (!mounted) return;
      setState(() => _visibleBounds = bounds);
    } catch (_) {}
  }

  void _onCameraMove(CameraPosition position) {
    if (_hasRunSearch) {
      _mapMoveDebounce?.cancel();
      _mapMoveDebounce = Timer(const Duration(milliseconds: 450), () async {
        _searchCenter = position.target;
        await _refreshNearbyPlaces();
        await _updateVisibleRegion();
        if (mounted) _rebuildMarkers();
      });
    }
  }

  void _rebuildMarkers() {
    final theme = Theme.of(context);
    final List<Marker> markers = [];

    if (_hasRunSearch) {
      final placeIds = _placesParks.map((e) => e.id).toSet();
      for (final placePark in _placesParks.where(_isInSearchArea)) {
        final livePark = _parks.firstWhere(
          (p) => p.id == placePark.id,
          orElse: () => placePark,
        );
        final totalPlayers = _getTotalPlayers(livePark);

        markers.add(
          Marker(
            markerId: MarkerId(placePark.id),
            position: LatLng(placePark.latitude, placePark.longitude),
            icon: _badgeIconCache[totalPlayers] ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
            onTap: () {
              setState(() => _selectedPark = livePark);
            },
          ),
        );

        if (!_badgeIconCache.containsKey(totalPlayers)) {
          _createBadgeMarker(totalPlayers, theme.colorScheme.primary, theme.colorScheme.secondary, theme.colorScheme.onPrimary)
              .then((icon) {
            _badgeIconCache[totalPlayers] = icon;
            if (mounted) _rebuildMarkers();
          });
        }
      }

      // Firestore-only parks (not present in Google Places list)
      for (final p in _parks.where(_isInSearchArea)) {
        if (placeIds.contains(p.id)) continue;
        final bool approved = p.approved;
        final String status = p.reviewStatus;
        final double hue = approved
            ? BitmapDescriptor.hueGreen
            : (status == 'denied' ? BitmapDescriptor.hueRed : BitmapDescriptor.hueOrange);
        markers.add(
          Marker(
            markerId: MarkerId('fs_${p.id}'),
            position: LatLng(p.latitude, p.longitude),
            icon: BitmapDescriptor.defaultMarkerWithHue(hue),
            onTap: () {
              setState(() => _selectedPark = p);
            },
          ),
        );
      }
    }

    if (_newParkLocation != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('new_park'),
          position: _newParkLocation!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          draggable: true,
          onDragEnd: (newPos) {
            setState(() => _newParkLocation = newPos);
          },
        ),
      );
    }

    setState(() {
      _markers = markers.toSet();
    });
  }

  Future<BitmapDescriptor> _createBadgeMarker(int count, Color baseColor, Color badgeColor, Color iconColor) async {
    const double size = 120; // high-res for sharpness
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    final Paint shadowPaint = Paint()..color = Colors.black.withValues(alpha: 0.15);
    final Paint circlePaint = Paint()..color = baseColor;
    final double radius = 40;

    // shadow
    canvas.drawCircle(const Offset(60, 63), radius, shadowPaint);
    // circle
    canvas.drawCircle(const Offset(60, 60), radius, circlePaint);

    // location icon glyph
    final TextPainter pin = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.location_on.codePoint),
        style: TextStyle(
          fontSize: 48,
          fontFamily: Icons.location_on.fontFamily,
          package: Icons.location_on.fontPackage,
          color: iconColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    pin.paint(canvas, Offset(60 - pin.width / 2, 60 - pin.height / 2));

    // badge
    final RRect badge = RRect.fromRectAndRadius(const Rect.fromLTWH(80, 20, 40, 26), const Radius.circular(12));
    final Paint badgePaint = Paint()..color = badgeColor;
    canvas.drawRRect(badge, badgePaint);

    // count text
    final TextPainter tp = TextPainter(
      text: TextSpan(text: '$count', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: 40);
    tp.paint(canvas, Offset(80 + (40 - tp.width) / 2, 20 + (26 - tp.height) / 2));

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(size.toInt(), size.toInt());
    final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final Uint8List pngBytes = bytes!.buffer.asUint8List();
    return BitmapDescriptor.fromBytes(pngBytes);
  }

  void _onMapTap(LatLng location) {
    setState(() {
      _newParkLocation = location;
    });
    _showAddParkDialog(location);
    _rebuildMarkers();
  }

  void _showAddParkDialog(LatLng location) {
    // Capture the parent Scaffold context so we can show SnackBars after closing the dialog
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
          // Perform reverse geocode once to auto-fill address fields.
          if (!didAutofill) {
            didAutofill = true;
            _placesService
                .reverseGeocode(latitude: location.latitude, longitude: location.longitude)
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
                    const Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.sports_tennis, size: 22, color: Colors.green),
                          SizedBox(width: 8),
                          Text('Pickleball Courts:'),
                        ],
                      ),
                    ),
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
                        'Location: ${( _newParkLocation?.latitude ?? location.latitude ).toStringAsFixed(4)}, ${( _newParkLocation?.longitude ?? location.longitude ).toStringAsFixed(4)}',
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
                  _rebuildMarkers();
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

                // Capture creator for approval workflow
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
                  latitude: _newParkLocation?.latitude ?? location.latitude,
                  longitude: _newParkLocation?.longitude ?? location.longitude,
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
                
                _parkService.addPark(newPark).then((_) {
                  _loadParks();
                  if (mounted) {
                    ScaffoldMessenger.of(parentContext).showSnackBar(
                      SnackBar(
                        content: Text(autoApprove
                            ? 'Published. Your new park is live.'
                            : 'Submitted. Admin will review your park. You\'ll be notified once approved.'),
                      ),
                    );
                  }
                });

                setState(() => _newParkLocation = null);
                _rebuildMarkers();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(
              target: LatLng(39.8283, -98.5795),
              zoom: 4,
            ),
            markers: _markers,
            onMapCreated: (controller) => _mapController = controller,
            onTap: _onMapTap,
            onCameraIdle: () async {
              await _updateVisibleRegion();
              if (_hasRunSearch) _rebuildMarkers();
            },
            onCameraMove: _onCameraMove,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            mapType: MapType.normal,
            zoomControlsEnabled: false,
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
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            right: 16,
            child: Column(
              children: [
                Hero(
                  tag: 'search_bar',
                  child: Material(
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
                              style: theme.textTheme.bodyMedium,
                              decoration: InputDecoration(
                                hintText: 'Search a city or address...',
                                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                              onSubmitted: (value) {
                                if (value.isNotEmpty) {
                                  _searchAddress(value);
                                }
                              },
                            ),
                          ),
                          if (_searchController.text.isNotEmpty)
                            IconButton(
                              icon: Icon(Icons.clear, size: 20, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                              onPressed: () {
                                _searchController.clear();
                                if (mounted) {
                                  setState(() {
                                    _isSearching = false;
                                  });
                                }
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                        ],
                      ),
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
                        Text(
                          'Finding location...',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          // Find me button on bottom-left (opposite side of zoom controls on web)
          Positioned(
            bottom: 24,
            left: 16,
            child: FloatingActionButton(
              heroTag: 'my_location',
              onPressed: () async {
                try {
                  final position = await LocationService().getCurrentLocation();
                  if (position != null && mounted) {
                    _mapController?.animateCamera(
                      CameraUpdate.newCameraPosition(
                        CameraPosition(
                          target: LatLng(position.latitude, position.longitude),
                          zoom: 15,
                        ),
                      ),
                    );
                  } else if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Unable to get your location. Enable location in device settings.'),
                        action: SnackBarAction(
                          label: 'OK',
                          onPressed: () {},
                        ),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Location access denied. Please enable it in your device or browser.'),
                      ),
                    );
                  }
                }
              },
              backgroundColor: theme.colorScheme.surface,
              child: Icon(Icons.my_location, color: theme.colorScheme.primary),
            ),
          ),

          // Add court action stays on bottom-right
          Positioned(
            bottom: 24,
            right: 16,
            child: FloatingActionButton.extended(
              heroTag: 'add_court',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Search an address or tap anywhere on the map to add courts',
                      style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
                    ),
                    backgroundColor: theme.colorScheme.primary,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    duration: const Duration(seconds: 3),
                  ),
                );
              },
              icon: const Icon(Icons.add_location),
              label: const Text('Add Court'),
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
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
        mainAxisSize: MainAxisSize.min,
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
