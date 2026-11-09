import 'dart:convert';

import 'package:compounder/data/store.dart';
import 'package:compounder/subscription/gateway.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Stands in for the gateway's register handler: records every request body
/// and echoes the token back the way `mobile::register` does.
class _Recorder {
  final List<Map<String, Object?>> bodies = [];
  int status = 200;
  bool omitToken = false;

  /// When set, the gateway answers with this token instead of echoing the
  /// client's. Used to prove the client reconciles a divergent issue.
  String? issuedOverride;

  MockClient client() => MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, Object?>);
        if (status != 200) {
          return http.Response(
              jsonEncode({
                'error': {'code': 'internal', 'message': 'boom'}
              }),
              status);
        }
        return http.Response(
            jsonEncode({
              'device_token': omitToken
                  ? null
                  : (issuedOverride ?? bodies.last['device_token']),
              'account_id': 'user-1',
            }),
            200);
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  late AppStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: inMemoryDatabasePath);
  });

  tearDown(() async {
    await store.db.close();
  });

  test('register sends a random device_token in the body', () async {
    final recorder = _Recorder();
    final client = GatewayClient(
      baseUrl: 'http://gateway.test',
      deviceTokenStore: store,
      httpClient: recorder.client(),
    );

    final token = await client.register();

    expect(recorder.bodies, hasLength(1));
    final sent = recorder.bodies.single['device_token'];
    expect(sent, isA<String>());
    expect((sent as String).length, inInclusiveRange(8, 512));
    expect(sent, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(recorder.bodies.single['platform'], 'android');
    expect(token, sent);
    expect(store.deviceToken, sent);
    expect(store.deviceTokenRegistered, isTrue);
  });

  test('a second register reuses the confirmed token without a request',
      () async {
    final recorder = _Recorder();
    final client = GatewayClient(
      baseUrl: 'http://gateway.test',
      deviceTokenStore: store,
      httpClient: recorder.client(),
    );

    final first = await client.register();
    final second = await client.register();

    expect(second, first);
    expect(recorder.bodies, hasLength(1),
        reason: 'a confirmed token must not be registered twice');
  });

  test('a failed register keeps the token so the retry reuses it', () async {
    final recorder = _Recorder()..status = 500;
    final client = GatewayClient(
      baseUrl: 'http://gateway.test',
      deviceTokenStore: store,
      httpClient: recorder.client(),
    );

    await expectLater(client.register(), throwsA(isA<GatewayException>()));

    final persisted = store.deviceToken;
    expect(persisted, isNotNull,
        reason: 'the token must be persisted before the network call');
    expect(persisted!.length, inInclusiveRange(8, 512));
    expect(store.deviceTokenRegistered, isFalse);

    recorder.status = 200;
    final token = await client.register();

    expect(recorder.bodies, hasLength(2));
    expect(recorder.bodies[1]['device_token'], persisted,
        reason: 'the retry must reuse the persisted identity');
    expect(token, persisted);
    expect(store.deviceTokenRegistered, isTrue);
  });

  test('the token is stable across clients sharing the same prefs', () async {
    final recorder = _Recorder();
    final first = GatewayClient(
      baseUrl: 'http://gateway.test',
      deviceTokenStore: store,
      httpClient: recorder.client(),
    );
    final token = await first.register();

    final reopened = await AppStore.open(await SharedPreferences.getInstance(),
        path: inMemoryDatabasePath);
    addTearDown(reopened.db.close);
    final second = GatewayClient(
      baseUrl: 'http://gateway.test',
      deviceTokenStore: reopened,
      httpClient: recorder.client(),
    );

    expect(await second.register(), token);
    expect(reopened.deviceToken, token);
    expect(recorder.bodies, hasLength(1));
  });

  test('each fresh install mints a distinct 43-character token', () async {
    final tokens = <String>[];
    Future<String> registerFresh() async {
      final recorder = _Recorder();
      final client = GatewayClient(
        baseUrl: 'http://gateway.test',
        httpClient: recorder.client(),
      );
      final token = await client.register();
      tokens.add(recorder.bodies.single['device_token'] as String);
      return token;
    }

    await registerFresh();
    await registerFresh();

    expect(tokens, hasLength(2));
    expect(tokens[0], isNot(tokens[1]),
        reason: 'Random.secure must not repeat a token');
    expect(tokens[0].length, 43);
  });

  test('the platform is reported from the injected platform', () async {
    final recorder = _Recorder();
    final client = GatewayClient(
      baseUrl: 'http://gateway.test',
      deviceTokenStore: store,
      platform: 'ios',
      httpClient: recorder.client(),
    );

    await client.register();

    expect(recorder.bodies.single['platform'], 'ios');
  });

  test('the platform fallback reports other on a non-mobile platform',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final recorder = _Recorder();
    final client = GatewayClient(
      baseUrl: 'http://gateway.test',
      deviceTokenStore: store,
      httpClient: recorder.client(),
    );

    await client.register();

    expect(recorder.bodies.single['platform'], 'other',
        reason: 'a desktop build must not claim to be Android');
  });

  test('a gateway that issues a different token is adopted, not ignored',
      () async {
    final recorder = _Recorder()..issuedOverride = 'gateway-issued-token-123';
    final client = GatewayClient(
      baseUrl: 'http://gateway.test',
      deviceTokenStore: store,
      httpClient: recorder.client(),
    );

    final token = await client.register();

    expect(token, 'gateway-issued-token-123');
    expect(store.deviceToken, 'gateway-issued-token-123',
        reason: 'the persisted identity must be the token the gateway knows');
    expect(store.deviceTokenRegistered, isTrue);
    expect(recorder.bodies.single['device_token'], isNot(token),
        reason: 'the client minted a different token than the gateway issued');
  });

  test('a response without a device_token is still an error', () async {
    final recorder = _Recorder()..omitToken = true;
    final client = GatewayClient(
      baseUrl: 'http://gateway.test',
      deviceTokenStore: store,
      httpClient: recorder.client(),
    );

    await expectLater(
      client.register(),
      throwsA(isA<GatewayException>().having((e) => e.message, 'message',
          'Compounder AI did not return a device token. Try again later.')),
    );
    expect(store.deviceTokenRegistered, isFalse);
  });
}
