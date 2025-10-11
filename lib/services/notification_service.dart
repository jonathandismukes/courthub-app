import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hoopsight/main.dart';
import 'package:hoopsight/screens/park_detail_page.dart';
import 'package:hoopsight/services/park_service.dart';

class NotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  StreamSubscription<String>? _tokenRefreshSubscription;

  Future<void> initialize() async {
    // Do NOT request push permission here. We defer until the user enables it.
    await _initializeLocalNotifications();
    await _configureForegroundNotifications();
    await _configureBackgroundNotificationHandlers();
    // Do not call getToken() here on web/iOS; it implicitly requires permission.
    // We fetch and save the token only after the user explicitly enables notifications
    // from the Profile page toggle (requestNotificationPermission + ensureAndSaveFCMToken).
    // Token refresh listener will be set up after successful token save.
  }


  Future<void> _initializeLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    // On iOS, do not request permissions during initialization.
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
  }

  Future<void> _configureForegroundNotifications() async {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('Foreground message: ${message.notification?.title}');
      if (message.notification != null) {
        _showLocalNotification(
          message.notification!.title ?? 'Notification',
          message.notification!.body ?? '',
          message.data,
        );
      }
    });
  }

  Future<void> _configureBackgroundNotificationHandlers() async {
    // Handle notification tap when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('Notification opened app from background: ${message.data}');
      _handleNotificationClick(message.data);
    });

    // Handle notification tap when app was terminated
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('Notification opened app from terminated state: ${initialMessage.data}');
      Future.delayed(const Duration(seconds: 1), () {
        _handleNotificationClick(initialMessage.data);
      });
    }
  }

  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('Local notification tapped: ${response.payload}');
    if (response.payload != null) {
      final parts = response.payload!.split('|');
      if (parts.length >= 2) {
        _handleNotificationClick({'type': parts[0], 'parkId': parts[1]});
      }
    }
  }

  void _handleNotificationClick(Map<String, dynamic> data) async {
    final type = data['type'];
    final parkId = data['parkId'];

    if (type == 'checkin' && parkId != null) {
      // Fetch park data and navigate to park detail page
      final context = navigatorKey.currentContext;
      if (context != null) {
        try {
          final park = await ParkService().getPark(parkId);
          if (park != null && context.mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ParkDetailPage(park: park),
              ),
            );
          }
        } catch (e) {
          debugPrint('Error fetching park for notification: $e');
        }
      }
    }
  }

  Future<void> _showLocalNotification(String title, String body, Map<String, dynamic> data) async {
    final payload = '${data['type'] ?? 'unknown'}|${data['parkId'] ?? ''}';
    
    const androidDetails = AndroidNotificationDetails(
      'courthub_channel',
      'Courthub Notifications',
      channelDescription: 'Notifications for game invites and friend requests',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch % 100000,
      title,
      body,
      details,
      payload: payload,
    );
  }

  /// Ensures FCM token is obtained and saved for the given user.
  /// Retries up to 3 times if token is null, and sets up token refresh listener.
  Future<bool> ensureAndSaveFCMToken(String userId) async {
    debugPrint('🔔 Starting FCM token setup for user: $userId');
    
    // Try to get token with retries
    String? token;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        token = await _messaging.getToken();
        if (token != null) {
          debugPrint('✅ FCM token obtained on attempt $attempt');
          break;
        }
        debugPrint('⚠️ FCM token is null on attempt $attempt, retrying...');
        await Future.delayed(Duration(seconds: attempt)); // Exponential backoff
      } catch (e) {
        debugPrint('⚠️ Error getting FCM token on attempt $attempt: $e');
        if (attempt == 3) {
          debugPrint('❌ Failed to get FCM token after 3 attempts');
          return false;
        }
        await Future.delayed(Duration(seconds: attempt));
      }
    }

    // Save token to Firestore
    if (token != null) {
      final success = await _saveFCMTokenToFirestore(userId, token);
      if (success) {
        // Set up token refresh listener
        _setupTokenRefreshListener(userId);
        return true;
      }
    }
    
    // Even if we couldn't get the token now, set up the refresh listener
    // so we can save it when it becomes available
    debugPrint('⚠️ Setting up token refresh listener for future token availability');
    _setupTokenRefreshListener(userId);
    return false;
  }

  /// Sets up a listener for FCM token refresh events
  void _setupTokenRefreshListener(String userId) {
    // Cancel existing subscription if any
    _tokenRefreshSubscription?.cancel();
    
    _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((newToken) {
      debugPrint('🔄 FCM Token refreshed: $newToken');
      _saveFCMTokenToFirestore(userId, newToken);
    });
  }

  /// Saves the FCM token to Firestore
  Future<bool> _saveFCMTokenToFirestore(String userId, String token) async {
    try {
      await _db.collection('users').doc(userId).collection('tokens').doc(token).set({
        'token': token,
        'platform': 'web',
        'createdAt': DateTime.now().toIso8601String(),
      });
      await _db.collection('users').doc(userId).update({
        'fcmToken': token,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      debugPrint('✅ FCM token saved successfully for user: $userId');
      return true;
    } catch (e) {
      debugPrint('⚠️ Failed to save FCM token to Firestore: $e');
      return false;
    }
  }

  /// Removes FCM token from Firestore (for logout or when user disables notifications)
  Future<void> removeFCMToken(String userId) async {
    try {
      final token = await _messaging.getToken();
      if (token != null) {
        // Remove token from tokens subcollection
        await _db.collection('users').doc(userId).collection('tokens').doc(token).delete();
        
        // Remove fcmToken field from user document
        await _db.collection('users').doc(userId).update({
          'fcmToken': FieldValue.delete(),
          'updatedAt': DateTime.now().toIso8601String(),
        });
        debugPrint('✅ FCM token removed for user: $userId');
      }
      
      // Cancel token refresh listener
      _tokenRefreshSubscription?.cancel();
      _tokenRefreshSubscription = null;
    } catch (e) {
      debugPrint('⚠️ Failed to remove FCM token: $e');
    }
  }

  /// Checks if notifications are enabled (permission granted)
  Future<bool> areNotificationsEnabled() async {
    final settings = await _messaging.getNotificationSettings();
    return settings.authorizationStatus == AuthorizationStatus.authorized;
  }

  /// Requests notification permission and returns whether it was granted
  Future<bool> requestNotificationPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized;
  }

  @Deprecated('Use ensureAndSaveFCMToken instead')
  Future<void> saveFCMToken(String userId) async {
    // Keep for backwards compatibility, but redirect to new method
    await ensureAndSaveFCMToken(userId);
  }

  Future<void> sendFriendRequestNotification(String userId, String senderName) async {
    await _db.collection('notifications').add({
      'userId': userId,
      'type': 'friend_request',
      'senderName': senderName,
      'title': 'New Friend Request',
      'body': '$senderName sent you a friend request',
      'createdAt': DateTime.now().toIso8601String(),
      'read': false,
    });
    debugPrint('Created friend request notification document for: $userId from $senderName');
  }

  Future<void> sendGameInviteNotification(String userId, String senderName, String parkName, DateTime scheduledTime) async {
    final formattedTime = '${scheduledTime.month}/${scheduledTime.day} at ${scheduledTime.hour}:${scheduledTime.minute.toString().padLeft(2, '0')}';
    await _db.collection('notifications').add({
      'userId': userId,
      'type': 'game_invite',
      'senderName': senderName,
      'parkName': parkName,
      'scheduledTime': scheduledTime.toIso8601String(),
      'title': '🏀 Game Invite',
      'body': '$senderName invited you to play at $parkName on $formattedTime',
      'createdAt': DateTime.now().toIso8601String(),
      'read': false,
    });
    debugPrint('Created game invite notification document for: $userId from $senderName at $parkName');
  }

  Future<void> sendNowPlayingNotification(String userId, String senderName, String parkName, int courtNumber) async {
    await _db.collection('notifications').add({
      'userId': userId,
      'type': 'now_playing',
      'senderName': senderName,
      'parkName': parkName,
      'courtNumber': courtNumber,
      'title': '🏀 Playing Now',
      'body': '$senderName is playing now at $parkName on Court $courtNumber',
      'createdAt': DateTime.now().toIso8601String(),
      'read': false,
    });
    debugPrint('Created now playing notification document for: $userId from $senderName at $parkName Court $courtNumber');
  }

  Future<void> sendCheckInNotification(String parkId, String parkName, String userName) async {
    // Cloud Function handles this automatically via Firestore trigger
    debugPrint('Check-in notification will be handled by Cloud Function for park: $parkName');
  }
}
