/// Centralized runtime configuration for API keys and other public client keys.
///
/// IMPORTANT: These keys run in client apps and will be visible to users.
/// Restrict them in the provider console (HTTP referrer bundle IDs, package name + SHA, etc.).
class KeysConfig {
  /// Google Maps/Places/Geocoding API key used by client-side requests.
  /// - Mobile: Also add platform-specific keys per the instructions in Android/iOS folders.
  /// - Web: Restrict by your deployed domain.
  static const String googleApiKey = 'REPLACE_WITH_YOUR_GOOGLE_API_KEY';
}
