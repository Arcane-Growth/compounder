import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:http/http.dart' as http;

import 'constants.dart';
import 'entitlement.dart';

/// Persistence for the per-install device identity.
///
/// The gateway keys an install off the device token, so the token must survive
/// a failed register: it is written before the network call and reused on the
/// retry. [AppStore] implements this.
abstract class DeviceTokenStore {
  /// The token persisted for this install, or null if none was minted yet.
  String? get deviceToken;

  /// Whether the gateway has accepted [deviceToken].
  bool get deviceTokenRegistered;

  /// Persists [token] as this install's identity, not yet confirmed.
  Future<void> saveDeviceToken(String token);

  /// Records that the gateway accepted the persisted token.
  Future<void> markDeviceTokenRegistered();
}

/// A gateway call failed.
///
/// [message] is safe to show to the user as-is; [unreachable] distinguishes
/// "no network / gateway down" from "the gateway said no", which the UI words
/// differently.
class GatewayException implements Exception {
  final String message;
  final bool unreachable;
  final int? statusCode;
  final String? code;

  const GatewayException(
    this.message, {
    this.unreachable = false,
    this.statusCode,
    this.code,
  });

  @override
  String toString() => message;
}

/// The gateway's answer to a verify / restore / entitlement call.
class GatewayEntitlement {
  final String? apiKey;
  final Entitlement entitlement;

  const GatewayEntitlement({this.apiKey, required this.entitlement});
}

/// Client for the mobile endpoints on gateway.arcanegrowth.com.
///
/// The endpoints and payloads are the contract agreed with the gateway team:
/// register, store/google/verify, store/apple/verify, restore, entitlement.
class GatewayClient {
  final String baseUrl;
  final http.Client _http;
  final Duration timeout;

  /// Where the per-install device token is persisted. Null in tests that do
  /// not care about identity; the token is then minted per call.
  final DeviceTokenStore? deviceTokenStore;

  /// Reported to the gateway on register. Injected so tests can pin it.
  final String platform;

  GatewayClient({
    this.baseUrl = gatewayBaseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
    this.deviceTokenStore,
    String? platform,
  })  : _http = httpClient ?? http.Client(),
        platform = platform ?? _defaultPlatform();

  /// The platform reported on register. The app ships on Android and iOS;
  /// desktop and web builds report `other` rather than claiming to be Android.
  static String _defaultPlatform() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return 'other';
    }
  }

  /// Registers this install and returns the device token the gateway issues.
  ///
  /// The gateway requires the token in the body (8-512 characters). It is
  /// minted client-side, persisted before the request, and reused afterwards,
  /// so a failed register retries with the same identity instead of creating a
  /// new account on every attempt.
  Future<String> register() async {
    final store = deviceTokenStore;
    final cached = store?.deviceToken;
    final String token;
    if (cached != null && _isValidDeviceToken(cached)) {
      if (store != null && store.deviceTokenRegistered) return cached;
      token = cached;
    } else {
      token = _newDeviceToken();
    }
    await store?.saveDeviceToken(token);
    final json = await _post('/api/mobile/register', {
      'device_token': token,
      'platform': platform,
    });
    final issued = json['device_token'];
    if (issued is! String || issued.isEmpty) {
      throw const GatewayException(
          'Compounder AI did not return a device token. Try again later.');
    }
    // The gateway echoes the client-minted token today. If it ever issues a
    // different one, adopt it: the store must mark the identity the gateway
    // actually knows as registered, otherwise the next call sends a token the
    // gateway never saw.
    if (issued != token) {
      await store?.saveDeviceToken(issued);
    }
    await store?.markDeviceTokenRegistered();
    return issued;
  }

  /// 32 random bytes, base64url without padding: 43 characters, inside the
  /// gateway's 8-512 character window.
  static String _newDeviceToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static bool _isValidDeviceToken(String token) =>
      token.length >= 8 && token.length <= 512;

  Future<GatewayEntitlement> verifyGoogle({
    required String productId,
    required String purchaseToken,
    String? deviceToken,
  }) async {
    final json = await _post(
      '/api/mobile/store/google/verify',
      {'product_id': productId, 'purchase_token': purchaseToken},
      deviceToken: deviceToken,
    );
    return _entitlement(json);
  }

  Future<GatewayEntitlement> verifyApple({
    required String productId,
    required String transactionId,
    String? deviceToken,
  }) async {
    final json = await _post(
      '/api/mobile/store/apple/verify',
      {'product_id': productId, 'transaction_id': transactionId},
      deviceToken: deviceToken,
    );
    return _entitlement(json);
  }

  /// Server-side restore, used when the store has nothing to replay.
  Future<GatewayEntitlement> restore({String? apiKey, String? deviceToken}) async {
    final json = await _post('/api/mobile/restore', const {},
        apiKey: apiKey, deviceToken: deviceToken);
    return _entitlement(json);
  }

  /// Current entitlement and quota for an issued API key.
  Future<GatewayEntitlement> entitlement(String apiKey) async {
    final json = await _get('/api/mobile/entitlement', apiKey: apiKey);
    return _entitlement(json);
  }

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body, {
    String? apiKey,
    String? deviceToken,
  }) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (apiKey != null && apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    // The contract does not put the device token in the verify body, so it
    // travels as a header. The gateway ignores it if it does not need it.
    if (deviceToken != null && deviceToken.isNotEmpty) {
      headers['X-Device-Token'] = deviceToken;
    }
    return _send(() => _http.post(Uri.parse('$baseUrl$path'),
        headers: headers, body: jsonEncode(body)));
  }

  Future<Map<String, Object?>> _get(String path, {String? apiKey}) async {
    final headers = <String, String>{};
    if (apiKey != null && apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    return _send(() => _http.get(Uri.parse('$baseUrl$path'), headers: headers));
  }

  Future<Map<String, Object?>> _send(
      Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      throw const GatewayException(
          "Can't reach Compounder AI — the request timed out.",
          unreachable: true);
    } on SocketException {
      throw const GatewayException(
          "Can't reach Compounder AI. Check your connection.",
          unreachable: true);
    } on http.ClientException {
      throw const GatewayException(
          "Can't reach Compounder AI. Check your connection.",
          unreachable: true);
    }
    final decoded = _decode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = decoded['error'];
      final code = error is Map ? error['code'] as String? : null;
      final message = error is Map && error['message'] is String
          ? error['message'] as String
          : 'Compounder AI returned an error (${response.statusCode}).';
      throw GatewayException(message,
          statusCode: response.statusCode, code: code);
    }
    return decoded;
  }

  Map<String, Object?> _decode(String body) {
    if (body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded.cast<String, Object?>() : const {};
    } catch (_) {
      return const {};
    }
  }

  GatewayEntitlement _entitlement(Map<String, Object?> json) {
    final entitlementJson = json['entitlement'];
    final quotaJson = json['quota'];
    final entitlement = Entitlement(
      status: parseEntitlementStatus(
          entitlementJson is Map ? entitlementJson['status'] : null),
      planCode: json['plan_code'] is String ? json['plan_code'] as String : '',
      currentPeriodEnd: entitlementJson is Map
          ? _periodEnd(entitlementJson['current_period_end'])
          : null,
      quota: quotaJson is Map
          ? Quota.fromJson(quotaJson.cast<String, Object?>())
          : null,
      fetchedAt: DateTime.now(),
    );
    return GatewayEntitlement(
      apiKey: json['api_key'] is String ? json['api_key'] as String : null,
      entitlement: entitlement,
    );
  }

  DateTime? _periodEnd(Object? raw) {
    if (raw is String) return DateTime.tryParse(raw)?.toLocal();
    if (raw is num) {
      final value = raw.toInt();
      if (value <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(
              value < 100000000000 ? value * 1000 : value)
          .toLocal();
    }
    return null;
  }
}
