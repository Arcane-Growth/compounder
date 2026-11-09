import 'dart:async';

import 'package:compounder/data/store.dart';
import 'package:compounder/subscription/entitlement.dart';
import 'package:compounder/subscription/gateway.dart';
import 'package:compounder/subscription/secrets.dart';
import 'package:compounder/subscription/service.dart';
import 'package:compounder/subscription/state.dart';
import 'package:compounder/subscription/store_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// In-memory secret store: the real one talks to the platform keystore.
class FakeSecrets implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class FakeStoreGateway implements StoreGateway {
  bool available = true;
  List<StoreProduct> products = const [];
  final StreamController<PurchaseEvent> _events =
      StreamController<PurchaseEvent>.broadcast();
  final List<String> bought = [];
  final List<PurchaseEvent> completed = [];
  int restoreCalls = 0;

  /// Event emitted when [buy] is called (null = the store stays silent).
  PurchaseEvent? purchaseEvent;

  /// Event emitted when [restore] is called (null = nothing to replay).
  PurchaseEvent? restoreEvent;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<StoreProduct>> queryProducts(List<String> ids) async =>
      products.where((p) => ids.contains(p.id)).toList();

  @override
  Stream<PurchaseEvent> get events => _events.stream;

  @override
  Future<void> buy(StoreProduct product) async {
    bought.add(product.id);
    final event = purchaseEvent;
    if (event != null) _events.add(event);
  }

  @override
  Future<void> restore() async {
    restoreCalls++;
    final event = restoreEvent;
    if (event != null) _events.add(event);
  }

  @override
  Future<void> complete(PurchaseEvent event) async => completed.add(event);

  @override
  Future<void> dispose() async => _events.close();
}

class FakeGateway extends GatewayClient {
  FakeGateway() : super(baseUrl: 'http://gateway.test');

  GatewayEntitlement? verifyResult;
  GatewayException? verifyError;
  GatewayEntitlement? restoreResult;
  GatewayException? restoreError;
  GatewayEntitlement? entitlementResult;
  GatewayException? entitlementError;
  String? deviceTokenResult = 'device-token';
  int registerCalls = 0;
  final List<Map<String, String>> verifications = [];

  @override
  Future<String> register() async {
    registerCalls++;
    return deviceTokenResult!;
  }

  @override
  Future<GatewayEntitlement> verifyGoogle({
    required String productId,
    required String purchaseToken,
    String? deviceToken,
  }) async {
    verifications.add({'product': productId, 'token': purchaseToken});
    if (verifyError != null) throw verifyError!;
    return verifyResult!;
  }

  @override
  Future<GatewayEntitlement> verifyApple({
    required String productId,
    required String transactionId,
    String? deviceToken,
  }) async {
    verifications.add({'product': productId, 'token': transactionId});
    if (verifyError != null) throw verifyError!;
    return verifyResult!;
  }

  @override
  Future<GatewayEntitlement> restore({String? apiKey, String? deviceToken}) async {
    if (restoreError != null) throw restoreError!;
    return restoreResult!;
  }

  @override
  Future<GatewayEntitlement> entitlement(String apiKey) async {
    if (entitlementError != null) throw entitlementError!;
    return entitlementResult!;
  }
}

const _monthly = StoreProduct(
  id: 'compounder_ai_monthly',
  title: 'Compounder AI monthly',
  price: r'$4.99',
  rawPrice: 4.99,
  currencyCode: 'USD',
);

Entitlement _active({DateTime? end}) => Entitlement(
      status: EntitlementStatus.active,
      planCode: 'monthly',
      currentPeriodEnd: end ?? DateTime.now().add(const Duration(days: 30)),
      quota: const Quota(dailyLimit: 20, dailyUsed: 3),
      fetchedAt: DateTime.now(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  group('entitlement state machine', () {
    final now = DateTime(2026, 11, 9, 12);

    test('an empty product list means the store is unavailable', () {
      final state = reduceSubscriptionState(
          const SubscriptionLoading(), const ProductsLoaded([]),
          now: now);
      expect(state, isA<SubscriptionStoreUnavailable>());
    });

    test('products move the screen to available', () {
      final state = reduceSubscriptionState(
          const SubscriptionLoading(), const ProductsLoaded([_monthly]),
          now: now);
      expect(state, isA<SubscriptionAvailable>());
      expect((state as SubscriptionAvailable).products.single.price, r'$4.99');
    });

    test('a started purchase is pending, never purchased', () {
      final state = reduceSubscriptionState(
          const SubscriptionAvailable([_monthly]),
          const PurchaseStarted('compounder_ai_monthly'),
          now: now);
      expect(state, isA<SubscriptionPending>());
    });

    test('only a gateway-verified active entitlement is purchased', () {
      final state = reduceSubscriptionState(
          const SubscriptionPending('compounder_ai_monthly'),
          PurchaseVerified(_active()),
          now: now);
      expect(state, isA<SubscriptionPurchased>());
    });

    test('a verified but inactive entitlement stays pending', () {
      final state = reduceSubscriptionState(
          const SubscriptionPending('compounder_ai_monthly'),
          PurchaseVerified(const Entitlement(status: EntitlementStatus.pending)),
          now: now);
      expect(state, isA<SubscriptionPending>());
    });

    test('an expired entitlement is not active', () {
      final expired = Entitlement(
        status: EntitlementStatus.active,
        currentPeriodEnd: now.subtract(const Duration(days: 1)),
      );
      expect(expired.isActiveAt(now), isFalse);
      final state = reduceSubscriptionState(
          const SubscriptionPending('compounder_ai_monthly'),
          PurchaseVerified(expired),
          now: now);
      expect(state, isA<SubscriptionPending>());
    });

    test('a refresh that reports expiry drops back to the plans', () {
      final state = reduceSubscriptionState(
          const SubscriptionAvailable([_monthly]),
          const EntitlementRefreshed(
              Entitlement(status: EntitlementStatus.none)),
          now: now);
      expect(state, isA<SubscriptionAvailable>());
    });

    test('a failed purchase surfaces an error', () {
      final state = reduceSubscriptionState(
          const SubscriptionPending('compounder_ai_monthly'),
          const PurchaseFailed('Card declined'),
          now: now);
      expect(state, isA<SubscriptionError>());
      expect((state as SubscriptionError).message, 'Card declined');
    });

    test('cached entitlement round-trips and corrupt cache is ignored', () {
      final cached = Entitlement.decodeCache(_active().encodeCache());
      expect(cached, isNotNull);
      expect(cached!.status, EntitlementStatus.active);
      expect(cached.quota!.dailyRemaining, 17);
      expect(Entitlement.decodeCache('{not json'), isNull);
      expect(Entitlement.decodeCache(null), isNull);
    });

    test('status strings map to the documented states', () {
      expect(parseEntitlementStatus('active'), EntitlementStatus.active);
      expect(parseEntitlementStatus('trialing'), EntitlementStatus.trialing,
          reason: 'a trial must not be collapsed into a paid subscription');
      expect(parseEntitlementStatus('grace_period'), EntitlementStatus.active);
      expect(parseEntitlementStatus('past_due'), EntitlementStatus.pastDue,
          reason: 'a grace-period subscription must not parse as unknown');
      expect(parseEntitlementStatus('free'), EntitlementStatus.active,
          reason: 'the gateway treats a free entitlement as entitled');
      expect(parseEntitlementStatus('pending'), EntitlementStatus.pending);
      expect(parseEntitlementStatus('expired'), EntitlementStatus.none);
      expect(parseEntitlementStatus('something-new'),
          EntitlementStatus.unknown);
      expect(parseEntitlementStatus(null), EntitlementStatus.unknown);
    });

    test('a trial grants access but stays a distinct trialing state', () {
      final trial = Entitlement(
        status: EntitlementStatus.trialing,
        planCode: 'monthly',
        currentPeriodEnd: now.add(const Duration(days: 7)),
      );
      expect(trial.isTrialing, isTrue);
      expect(trial.isActiveAt(now), isTrue,
          reason: 'quota applies during the trial');
      final state = reduceSubscriptionState(
          const SubscriptionPending('compounder_ai_monthly'),
          PurchaseVerified(trial),
          now: now);
      expect(state, isA<SubscriptionPurchased>());
      expect((state as SubscriptionPurchased).entitlement.status,
          EntitlementStatus.trialing,
          reason: 'the state machine must keep the trial status');
    });

    test('a trial that ended is not active and drops back to the plans', () {
      final ended = Entitlement(
        status: EntitlementStatus.trialing,
        currentPeriodEnd: now.subtract(const Duration(days: 1)),
      );
      expect(ended.isActiveAt(now), isFalse);
      final state = reduceSubscriptionState(
          const SubscriptionAvailable([_monthly]),
          EntitlementRefreshed(ended),
          now: now);
      expect(state, isA<SubscriptionAvailable>());
    });

    test('a trialing entitlement with no period end stays active', () {
      // Documented defensive fallback (`isActiveAt`): the gateway always sends
      // the trial end, so a null end is a dropped field, not an expiry. Fail
      // open to the gateway rather than revoke a paying trial user locally.
      const noEnd = Entitlement(status: EntitlementStatus.trialing);
      expect(noEnd.isActiveAt(now), isTrue);
      expect(noEnd.isActiveAt(now.add(const Duration(days: 3650))), isTrue,
          reason: 'without an end date the app cannot expire the trial itself');
    });

    test('a converted trial is a paid active entitlement', () {
      final converted = Entitlement(
        status: parseEntitlementStatus('active'),
        currentPeriodEnd: now.add(const Duration(days: 30)),
      );
      expect(converted.isTrialing, isFalse);
      expect(converted.isActiveAt(now), isTrue);
    });

    test('a cached trial round-trips as trialing', () {
      final cached = Entitlement.decodeCache(Entitlement(
        status: EntitlementStatus.trialing,
        planCode: 'monthly',
        currentPeriodEnd: now.add(const Duration(days: 7)),
      ).encodeCache());
      expect(cached!.status, EntitlementStatus.trialing);
      expect(cached.isTrialing, isTrue);
    });

    test('a past_due entitlement is active only inside the grace window', () {
      final inGrace = Entitlement(
        status: parseEntitlementStatus('past_due'),
        planCode: 'monthly',
        // The store's period end is already in the past for a past-due
        // subscription; only the grace end can grant access.
        currentPeriodEnd: now.subtract(const Duration(days: 2)),
        graceEndsAt: now.add(const Duration(days: 1)),
      );
      expect(inGrace.isPastDue, isTrue);
      expect(inGrace.isActiveAt(now), isTrue,
          reason: 'the gateway still accepts requests inside the grace window');
      expect(inGrace.isActiveAt(now.add(const Duration(days: 2))), isFalse,
          reason: 'access must end when the grace window closes');

      final noGrace = Entitlement(
        status: EntitlementStatus.pastDue,
        currentPeriodEnd: now.subtract(const Duration(days: 2)),
      );
      expect(noGrace.isActiveAt(now), isFalse,
          reason: 'a missing grace end means no access, matching the gateway');

      final state = reduceSubscriptionState(
          const SubscriptionPending('compounder_ai_monthly'),
          PurchaseVerified(inGrace),
          now: now);
      expect(state, isA<SubscriptionPurchased>(),
          reason: 'a past-due subscription inside grace must not look pending');
    });

    test('a past_due entitlement round-trips its grace end through the cache',
        () {
      final cached = Entitlement.decodeCache(Entitlement(
        status: EntitlementStatus.pastDue,
        planCode: 'monthly',
        currentPeriodEnd: now.subtract(const Duration(days: 2)),
        graceEndsAt: now.add(const Duration(days: 1)),
      ).encodeCache());
      expect(cached!.status, EntitlementStatus.pastDue);
      expect(cached.graceEndsAt, isNotNull);
      expect(cached.isActiveAt(now), isTrue);
    });
  });

  group('subscription service', () {
    late AppStore store;
    late FakeSecrets secrets;
    late FakeStoreGateway storeGateway;
    late FakeGateway gateway;
    late SubscriptionService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      secrets = FakeSecrets();
      store = await AppStore.open(prefs,
          path: inMemoryDatabasePath, secretStore: secrets);
      storeGateway = FakeStoreGateway()..products = const [_monthly];
      gateway = FakeGateway();
      service = SubscriptionService(
        store: store,
        storeGateway: storeGateway,
        gateway: gateway,
        secrets: secrets,
        restoreTimeout: const Duration(milliseconds: 50),
      );
    });

    tearDown(() async {
      service.dispose();
      await store.db.close();
    });

    test('an unavailable store renders the store-unavailable state', () async {
      storeGateway.available = false;
      await service.load();
      expect(service.state, isA<SubscriptionStoreUnavailable>());
    });

    test('products come from the store, never from the app', () async {
      await service.load();
      final state = service.state;
      expect(state, isA<SubscriptionAvailable>());
      expect((state as SubscriptionAvailable).products.single.price, r'$4.99');
    });

    test('a purchase is verified, keyed, cached and acknowledged', () async {
      gateway.verifyResult = GatewayEntitlement(
          apiKey: 'gw-key-123', entitlement: _active());
      storeGateway.purchaseEvent = const PurchaseEvent(
        outcome: PurchaseOutcome.purchased,
        productId: 'compounder_ai_monthly',
        token: 'play-token-abc',
      );
      await service.load();
      await service.buy('compounder_ai_monthly');
      await pumpEventQueue();

      expect(gateway.verifications.single,
          {'product': 'compounder_ai_monthly', 'token': 'play-token-abc'});
      expect(secrets.values[gatewayApiKeySecret], 'gw-key-123');
      expect(store.gatewayApiKey, 'gw-key-123');
      expect(store.aiSource, AiSource.compounder);
      expect(store.entitlement!.status, EntitlementStatus.active);
      expect(storeGateway.completed, hasLength(1));
      expect(service.state, isA<SubscriptionPurchased>());
    });

    test('a rejected verification keeps the purchase unacknowledged', () async {
      gateway.verifyError =
          const GatewayException('Purchase could not be verified.');
      storeGateway.purchaseEvent = const PurchaseEvent(
        outcome: PurchaseOutcome.purchased,
        productId: 'compounder_ai_monthly',
        token: 'play-token-abc',
      );
      await service.load();
      await service.buy('compounder_ai_monthly');
      await pumpEventQueue();

      expect(service.state, isA<SubscriptionError>());
      expect(secrets.values[gatewayApiKeySecret], isNull);
      expect(store.aiSource, AiSource.byo);
      expect(storeGateway.completed, isEmpty,
          reason: 'Play must retry an unverified purchase');
    });

    test('restore replays a store purchase', () async {
      gateway.verifyResult = GatewayEntitlement(
          apiKey: 'gw-key-123', entitlement: _active());
      storeGateway.restoreEvent = const PurchaseEvent(
        outcome: PurchaseOutcome.restored,
        productId: 'compounder_ai_monthly',
        token: 'play-token-abc',
      );
      await service.restore();
      await pumpEventQueue();

      expect(storeGateway.restoreCalls, 1);
      expect(service.state, isA<SubscriptionPurchased>());
      expect(store.gatewayApiKey, 'gw-key-123');
    });

    test('restore falls back to the gateway when the store is silent', () async {
      gateway.restoreResult =
          GatewayEntitlement(apiKey: 'gw-key-456', entitlement: _active());
      await service.restore();
      await pumpEventQueue();

      expect(service.state, isA<SubscriptionPurchased>());
      expect(store.gatewayApiKey, 'gw-key-456');
      expect(store.aiSource, AiSource.compounder);
    });

    test('restore with nothing to restore is an explicit error', () async {
      gateway.restoreResult = const GatewayEntitlement(
          entitlement: Entitlement(status: EntitlementStatus.none));
      await service.restore();
      await pumpEventQueue();

      expect(service.state, isA<SubscriptionError>());
      expect((service.state as SubscriptionError).message,
          contains('No previous Compounder AI purchase'));
    });

    test('an offline entitlement refresh keeps the cached plan', () async {
      gateway.verifyResult = GatewayEntitlement(
          apiKey: 'gw-key-123', entitlement: _active());
      storeGateway.purchaseEvent = const PurchaseEvent(
        outcome: PurchaseOutcome.purchased,
        productId: 'compounder_ai_monthly',
        token: 'play-token-abc',
      );
      await service.load();
      await service.buy('compounder_ai_monthly');
      await pumpEventQueue();
      expect(service.state, isA<SubscriptionPurchased>());

      gateway.entitlementError = const GatewayException(
          "Can't reach Compounder AI. Check your connection.",
          unreachable: true);
      await service.refreshEntitlement();
      expect(service.state, isA<SubscriptionPurchased>(),
          reason: 'offline must not drop the cached entitlement');
    });

    test('a pending store purchase shows the pending state', () async {
      storeGateway.purchaseEvent = const PurchaseEvent(
        outcome: PurchaseOutcome.pending,
        productId: 'compounder_ai_monthly',
      );
      await service.load();
      await service.buy('compounder_ai_monthly');
      await pumpEventQueue();
      expect(service.state, isA<SubscriptionPending>());
    });

    test('cancelling the store sheet returns to the plans', () async {
      storeGateway.purchaseEvent = const PurchaseEvent(
        outcome: PurchaseOutcome.canceled,
        productId: 'compounder_ai_monthly',
      );
      await service.load();
      await service.buy('compounder_ai_monthly');
      await pumpEventQueue();
      expect(service.state, isA<SubscriptionAvailable>());
    });
  });
}
