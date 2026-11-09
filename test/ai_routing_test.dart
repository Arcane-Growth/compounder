import 'dart:io';

import 'package:compounder/data/store.dart';
import 'package:compounder/llm/llm.dart';
import 'package:compounder/llm/routing.dart';
import 'package:compounder/subscription/constants.dart';
import 'package:compounder/subscription/entitlement.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A 429 from the gateway, exactly as the contract documents it.
ChatHttpException _quotaError() => const ChatHttpException(
      429,
      code: 'quota_exceeded',
      body: '{"error":{"code":"quota_exceeded","message":"daily limit"}}',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  late AppStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'baseUrl': 'https://my-endpoint.test/v1',
      'apiKey': 'byo-key',
      'model': 'my-model',
    });
    store = await AppStore.open(
      await SharedPreferences.getInstance(),
      path: inMemoryDatabasePath,
    );
  });

  tearDown(() async {
    await store.db.close();
  });

  group('quota rejection', () {
    test('a 429 is recognised as a quota rejection, other statuses are not',
        () {
      expect(_quotaError().quotaExceeded, isTrue);
      expect(const ChatHttpException(500).quotaExceeded, isFalse);
      expect(const ChatHttpException(401).quotaExceeded, isFalse);
    });

    test('the chat client turns a 429 body into a quota exception', () async {
      final client = ChatClient(
        gatewayChatBaseUrl,
        'gw-key',
        compounderAiModel,
        httpClient: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer gw-key');
          return http.Response(
              '{"error":{"code":"quota_exceeded","message":"daily limit"}}',
              429);
        }),
      );
      await expectLater(
        client.chat([ChatMessage.user('hi')], const []),
        throwsA(isA<ChatHttpException>()
            .having((e) => e.statusCode, 'statusCode', 429)
            .having((e) => e.code, 'code', 'quota_exceeded')
            .having((e) => e.quotaExceeded, 'quotaExceeded', isTrue)),
      );
    });

    test('a paid quota rejection is friendly and points at Settings', () {
      final message = friendlyAiError(_quotaError(), AiSource.compounder);
      expect(message, contains("today's Compounder AI requests"));
      expect(message, contains('Settings'));
      expect(message, isNot(contains('429')));
      expect(message, isNot(contains('Exception')));
    });

    test('a BYO quota rejection blames the endpoint, not the subscription', () {
      final message = friendlyAiError(_quotaError(), AiSource.byo);
      expect(message, contains('rate-limiting'));
      expect(message, isNot(contains('subscription')));
    });

    test('a rejected gateway key tells the user to restore the purchase', () {
      final message =
          friendlyAiError(const ChatHttpException(401), AiSource.compounder);
      expect(message, contains('Restore your purchase'));
    });

    test('an unreachable gateway is explained without a raw socket error', () {
      final message = friendlyAiError(
          const SocketException('Connection refused'), AiSource.compounder);
      expect(message, contains("Can't reach Compounder AI"));
      expect(message, contains('cached'));
      expect(message, isNot(contains('SocketException')));
    });
  });

  group('source routing', () {
    test('BYO is the default and routes to the user endpoint', () {
      expect(store.aiSource, AiSource.byo);
      final client = chatClientFor(store);
      expect(client.baseUrl, 'https://my-endpoint.test/v1');
      expect(client.apiKey, 'byo-key');
      expect(client.model, 'my-model');
      expect(aiConfigured(store), isTrue);
    });

    test('a paid source routes to the gateway with the issued key', () async {
      await store.setAiSource(AiSource.compounder);
      await store.saveGatewayKey('gw-key-123');
      final client = chatClientFor(store);
      expect(client.baseUrl, gatewayChatBaseUrl);
      expect(client.apiKey, 'gw-key-123');
      expect(client.model, compounderAiModel);
      expect(aiConfigured(store), isTrue);
    });

    test('a paid source without a key is not configured and says why',
        () async {
      await store.setAiSource(AiSource.compounder);
      expect(aiConfigured(store), isFalse);
      expect(aiNotConfiguredMessage(store.aiSource),
          contains('Settings → Compounder AI'));
    });

    test('switching back to BYO restores the original endpoint', () async {
      await store.setAiSource(AiSource.compounder);
      await store.saveGatewayKey('gw-key-123');
      await store.setAiSource(AiSource.byo);
      final client = chatClientFor(store);
      expect(client.baseUrl, 'https://my-endpoint.test/v1');
      expect(client.apiKey, 'byo-key');
    });
  });
}
