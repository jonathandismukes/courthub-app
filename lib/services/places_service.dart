import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:hoopsight/models/park_model.dart';
import 'package:hoopsight/config/keys.dart';

class PlacesService {
  static const String _apiKey = KeysConfig.googleApiKey;
  static const String _baseUrl = 'https://maps.googleapis.com/maps/api/place';
  // Using corsproxy.io as a more reliable CORS proxy
  static const String _corsProxy = 'https://corsproxy.io/?';

  bool get _isApiKeyConfigured => _apiKey.isNotEmpty && !_apiKey.contains('REPLACE_WITH_YOUR_GOOGLE_API_KEY');

  Future<List<Park>> searchCourts({
    required String city,
    required String state,
    required SportType sportType,
  }) async {
    try {
      if (!_isApiKeyConfigured) {
        debugPrint('❗ Google API key missing. Configure lib/config/keys.dart');
        throw Exception('GOOGLE_API_KEY_MISSING');
      }
      String sportName;
      switch (sportType) {
        case SportType.basketball:
          sportName = 'basketball';
          break;
        case SportType.pickleballSingles:
        case SportType.pickleballDoubles:
          sportName = 'pickleball';
          break;
        case SportType.tennisSingles:
        case SportType.tennisDoubles:
          sportName = 'tennis';
          break;
      }
      final query = '$city, $state $sportName court';
      final googleUrl = '$_baseUrl/textsearch/json?query=${Uri.encodeComponent(query)}&type=park&key=$_apiKey';
      final proxiedUrl = Uri.parse('$_corsProxy$googleUrl');

      debugPrint('🔍 Searching Google Places: $query');
      debugPrint('📍 Proxied URL: $proxiedUrl');

      final response = await http.get(proxiedUrl).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw Exception('Search request timed out'),
      );
      debugPrint('📊 Response status: ${response.statusCode}');
      debugPrint('📦 Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final status = data['status'];
        if (status == 'REQUEST_DENIED' || status == 'INVALID_REQUEST') {
          final msg = data['error_message'] ?? 'Request denied';
          debugPrint('❌ ERROR: $msg');
          throw Exception('GOOGLE_API_REQUEST_DENIED: $msg');
        }
        
        final results = data['results'] as List<dynamic>? ?? [];
        debugPrint('✅ Found ${results.length} results');
        
        return results.map((place) {
          final location = place['geometry']['location'];
          final placeId = place['place_id'] ?? '';
          final name = place['name'] ?? 'Unknown Court';
          final address = place['formatted_address'] ?? '';
          final now = DateTime.now();
          
          debugPrint('🏀 Park: $name at $address');
          
          return Park(
            id: placeId,
            name: name,
            address: address,
            city: city,
            state: state,
            latitude: location['lat'].toDouble(),
            longitude: location['lng'].toDouble(),
            courts: [
              Court(
                id: '$placeId-1',
                courtNumber: 1,
                playerCount: 0,
                sportType: sportType,
                lastUpdated: now,
              ),
            ],
            createdAt: now,
            updatedAt: now,
          );
        }).toList();
      } else {
        debugPrint('❌ ERROR: Response status ${response.statusCode}');
        return [];
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Error searching places: $e');
      debugPrint('📜 Stack trace: $stackTrace');
      return [];
    }
  }

  Future<List<Park>> searchNearby({
    required double latitude,
    required double longitude,
    required SportType sportType,
    int radius = 5000,
  }) async {
    try {
      if (!_isApiKeyConfigured) {
        debugPrint('❗ Google API key missing. Configure lib/config/keys.dart');
        throw Exception('GOOGLE_API_KEY_MISSING');
      }
      String sportKeyword;
      switch (sportType) {
        case SportType.basketball:
          sportKeyword = 'basketball';
          break;
        case SportType.pickleballSingles:
        case SportType.pickleballDoubles:
          sportKeyword = 'pickleball';
          break;
        case SportType.tennisSingles:
        case SportType.tennisDoubles:
          sportKeyword = 'tennis';
          break;
      }
      final googleUrl = '$_baseUrl/nearbysearch/json?location=$latitude,$longitude&radius=$radius&keyword=$sportKeyword+court&type=park&key=$_apiKey';
      final proxiedUrl = Uri.parse('$_corsProxy$googleUrl');

      final response = await http.get(proxiedUrl).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw Exception('Nearby search timed out'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final status = data['status'];
        if (status == 'REQUEST_DENIED' || status == 'INVALID_REQUEST') {
          final msg = data['error_message'] ?? 'Request denied';
          debugPrint('❌ ERROR: $msg');
          throw Exception('GOOGLE_API_REQUEST_DENIED: $msg');
        }
        final results = data['results'] as List<dynamic>? ?? [];
        
        return results.map((place) {
          final location = place['geometry']['location'];
          final placeId = place['place_id'] ?? '';
          final name = place['name'] ?? 'Unknown Court';
          final address = place['vicinity'] ?? '';
          final now = DateTime.now();
          
          return Park(
            id: placeId,
            name: name,
            address: address,
            city: '',
            state: '',
            latitude: location['lat'].toDouble(),
            longitude: location['lng'].toDouble(),
            courts: [
              Court(
                id: '$placeId-1',
                courtNumber: 1,
                playerCount: 0,
                sportType: sportType,
                lastUpdated: now,
              ),
            ],
            createdAt: now,
            updatedAt: now,
          );
        }).toList();
      }
      return [];
    } catch (e) {
      debugPrint('Error searching nearby: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> getPlaceDetails(String placeId) async {
    try {
      if (!_isApiKeyConfigured) {
        debugPrint('❗ Google API key missing. Configure lib/config/keys.dart');
        throw Exception('GOOGLE_API_KEY_MISSING');
      }
      final googleUrl = '$_baseUrl/details/json?place_id=$placeId&key=$_apiKey';
      final proxiedUrl = Uri.parse('$_corsProxy$googleUrl');

      final response = await http.get(proxiedUrl).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Place details request timed out'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final status = data['status'];
        if (status == 'REQUEST_DENIED' || status == 'INVALID_REQUEST') {
          final msg = data['error_message'] ?? 'Request denied';
          throw Exception('GOOGLE_API_REQUEST_DENIED: $msg');
        }
        return data['result'];
      }
      return null;
    } catch (e) {
      debugPrint('Error getting place details: $e');
      return null;
    }
  }

  /// Reverse geocode latitude/longitude into address fields.
  /// Returns a map with keys: address, city, state or null if not found.
  Future<Map<String, String>?> reverseGeocode({
    required double latitude,
    required double longitude,
  }) async {
    try {
      if (!_isApiKeyConfigured) {
        debugPrint('❗ Google API key missing. Configure lib/config/keys.dart');
        throw Exception('GOOGLE_API_KEY_MISSING');
      }
      final geocodeUrl = 'https://maps.googleapis.com/maps/api/geocode/json?latlng=$latitude,$longitude&key=$_apiKey';
      final uri = kIsWeb ? Uri.parse('$_corsProxy$geocodeUrl') : Uri.parse(geocodeUrl);

      final response = await http.get(uri).timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw Exception('Reverse geocoding timed out'),
      );

      if (response.statusCode != 200) return null;
      final Map<String, dynamic> data = json.decode(response.body) as Map<String, dynamic>;
      final status = data['status'];
      if (status == 'REQUEST_DENIED' || status == 'INVALID_REQUEST') {
        final msg = data['error_message'] ?? 'Request denied';
        throw Exception('GOOGLE_API_REQUEST_DENIED: $msg');
      }
      final results = data['results'] as List<dynamic>?;
      if (results == null || results.isEmpty) return null;

      final Map<String, dynamic> first = results.first as Map<String, dynamic>;
      final components = (first['address_components'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

      String? streetNumber;
      String? route;
      String? city;
      String? stateShort;

      for (final c in components) {
        final types = (c['types'] as List).cast<String>();
        if (types.contains('street_number')) streetNumber = c['long_name'] as String?;
        if (types.contains('route')) route = c['long_name'] as String?;
        if (types.contains('locality')) city = c['long_name'] as String?;
        if (types.contains('administrative_area_level_1')) stateShort = c['short_name'] as String?;
        if (city == null && (types.contains('postal_town') || types.contains('sublocality') || types.contains('neighborhood'))) {
          city = c['long_name'] as String?;
        }
      }

      final String address = [streetNumber, route].where((s) => s != null && s.trim().isNotEmpty).join(' ').trim();
      return {
        'address': address.isNotEmpty ? address : (first['formatted_address'] as String? ?? ''),
        'city': city ?? '',
        'state': stateShort ?? '',
      };
    } catch (e) {
      debugPrint('Reverse geocode error: $e');
      return null;
    }
  }
}
