import 'dart:convert';

import 'package:compounder/subscription/entitlement.dart';
import 'package:compounder/subscription/gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The gateway emits "past_due" for a grace-period subscription and grants
/// access inside the grace window. The app must decode the grace end, otherwise
/// it revokes access while the gateway still accepts requests.
void main() {
  test('a past_due verify response carries the grace end into the model',
      () async {
    final grace = DateTime.now().toUtc().add(const Duration(days: 1));
    final client = GatewayClient(
      baseUrl: 'http://gateway.test',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/mobile/store/google/verify');
        return http.Response(
            jsonEncode({
              'api_key': 'lgw_test',
              'plan_code': 'monthly',
              'entitlement': {
                'status': 'past_due',
                'current_period_end': DateTime.now()
                    .toUtc()
                    .subtract(const Duration(days: 2))
                    .toIso8601String(),
                'grace_ends_at': grace.toIso8601String(),
              },
              'quota': {
                'daily_requests_limit': 20,
                'daily_requests_used': 3,
                'monthly_tokens_limit': 1000,
                'monthly_tokens_used': 10,
              },
            }),
            200);
      }),
    );

    final result = await client.verifyGoogle(
        productId: 'compounder_ai_monthly', purchaseToken: 'token');

    expect(result.entitlement.status, EntitlementStatus.pastDue);
    expect(result.entitlement.isPastDue, isTrue);
    expect(result.entitlement.graceEndsAt, isNotNull,
        reason: 'the grace end is the only date that grants access');
    expect(result.entitlement.isActiveAt(DateTime.now()), isTrue,
        reason: 'the gateway accepts requests inside the grace window');
  });

  test('a past_due response without a grace end grants no access', () async {
    final client = GatewayClient(
      baseUrl: 'http://gateway.test',
      httpClient: MockClient((request) async {
        return http.Response(
            jsonEncode({
              'api_key': null,
              'plan_code': 'monthly',
              'entitlement': {
                'status': 'past_due',
                'current_period_end': DateTime.now()
                    .toUtc()
                    .subtract(const Duration(days: 2))
                    .toIso8601String(),
              },
              'quota': {
                'daily_requests_limit': 20,
                'daily_requests_used': 3,
                'monthly_tokens_limit': 1000,
                'monthly_tokens_used': 10,
              },
            }),
            200);
      }),
    );

    final result = await client.verifyGoogle(
        productId: 'compounder_ai_monthly', purchaseToken: 'token');

    expect(result.entitlement.status, EntitlementStatus.pastDue);
    expect(result.entitlement.graceEndsAt, isNull);
    expect(result.entitlement.isActiveAt(DateTime.now()), isFalse,
        reason: 'no grace end means no access, matching the gateway');
  });
}
