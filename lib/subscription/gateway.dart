import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'constants.dart';
import 'entitlement.dart';

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

  GatewayClient({
    this.baseUrl = gatewayBaseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
  }) : _http = httpClient ?? http.Client();

  /// Registers this install and returns the device token the gateway issues.
  Future<String> register() async {
    final json = await _post('/api/mobile/register', const {});
    final token = json['device_token'];
    if (token is! String || token.isEmpty) {
      throw const GatewayException(
          'Compounder AI did not return a device token. Try again later.');
    }
    return token;
  }

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
