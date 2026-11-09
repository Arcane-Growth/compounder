import 'dart:convert';

import 'package:compounder/subscription/gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('register must send the device_token the gateway requires', () async {
    late String body;
    final client = GatewayClient(
      baseUrl: 'http://gateway.test',
      httpClient: MockClient((req) async {
        body = req.body;
        return http.Response(
            jsonEncode({'device_token': 'x', 'account_id': 'u'}), 200);
      }),
    );
    await client.register();
    expect(jsonDecode(body), containsPair('device_token', anything));
  });
}
