import 'dart:async';

import 'package:compounder/data/store.dart';
import 'package:compounder/subscription/entitlement.dart';
import 'package:compounder/subscription/gateway.dart';
import 'package:compounder/subscription/secrets.dart';
import 'package:compounder/subscription/service.dart';
import 'package:compounder/subscription/store_gateway.dart';
import 'package:compounder/ui/subscription.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeSecrets implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Store double: prices come from here, exactly like the real store.
class FakeStoreGateway implements StoreGateway {
  bool available = true;
  List<StoreProduct> products = const [];
  final StreamController<PurchaseEvent> _events =
      StreamController<PurchaseEvent>.broadcast();
  final List<String> bought = [];
  PurchaseEvent? purchaseEvent;

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
  Future<void> restore() async {}

  @override
  Future<void> complete(PurchaseEvent event) async {}

  @override
  Future<void> dispose() async => _events.close();
}

class FakeGateway extends GatewayClient {
  FakeGateway() : super(baseUrl: 'http://gateway.test');

  GatewayEntitlement? verifyResult;
  GatewayException? verifyError;

  @override
  Future<String> register() async => 'device-token';

  @override
  Future<GatewayEntitlement> verifyGoogle({
    required String productId,
    required String purchaseToken,
    String? deviceToken,
  }) async {
    if (verifyError != null) throw verifyError!;
    return verifyResult!;
  }

  @override
  Future<GatewayEntitlement> verifyApple({
    required String productId,
    required String transactionId,
    String? deviceToken,
  }) async {
    if (verifyError != null) throw verifyError!;
    return verifyResult!;
  }
}

const _monthly = StoreProduct(
  id: 'compounder_ai_monthly',
  title: 'Compounder AI monthly',
  price: r'$4.99',
  rawPrice: 4.99,
  currencyCode: 'USD',
);

const _annual = StoreProduct(
  id: 'compounder_ai_annual',
  title: 'Compounder AI annual',
  price: r'$39.99',
  rawPrice: 39.99,
  currencyCode: 'USD',
);

Entitlement _active() => Entitlement(
      status: EntitlementStatus.active,
      planCode: 'monthly',
      currentPeriodEnd: DateTime.now().add(const Duration(days: 30)),
      quota: const Quota(dailyLimit: 20, dailyUsed: 3),
      fetchedAt: DateTime.now(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  late AppStore store;
  late FakeStoreGateway storeGateway;
  late FakeGateway gateway;
  late SubscriptionService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AppStore.open(
      await SharedPreferences.getInstance(),
      path: inMemoryDatabasePath,
    );
    storeGateway = FakeStoreGateway();
    gateway = FakeGateway();
    service = SubscriptionService(
      store: store,
      storeGateway: storeGateway,
      gateway: gateway,
      secrets: FakeSecrets(),
    );
  });

  tearDown(() async {
    await store.db.close();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SubscriptionScreen(service: service),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('store unavailable renders an explicit state, not a price',
      (tester) async {
    storeGateway.available = false;
    await pumpScreen(tester);

    expect(find.text('Store unavailable'), findsOneWidget);
    expect(find.textContaining('not available on this device'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text(r'$4.99'), findsNothing);
  });

  testWidgets('plans and prices come from the store', (tester) async {
    storeGateway.products = const [_monthly, _annual];
    await pumpScreen(tester);

    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Annual'), findsOneWidget);
    expect(find.text(r'$4.99'), findsOneWidget);
    expect(find.text(r'$39.99'), findsOneWidget);
    expect(find.text('Subscribe'), findsNWidgets(2));
    expect(find.text('Restore purchases'), findsOneWidget);
  });

  testWidgets('a purchase is verified and the screen shows the active plan',
      (tester) async {
    storeGateway.products = const [_monthly, _annual];
    storeGateway.purchaseEvent = const PurchaseEvent(
      outcome: PurchaseOutcome.purchased,
      productId: 'compounder_ai_monthly',
      token: 'play-token-abc',
    );
    gateway.verifyResult =
        GatewayEntitlement(apiKey: 'gw-key-123', entitlement: _active());
    await pumpScreen(tester);

    await tester.tap(find.text('Subscribe').first);
    await tester.pumpAndSettle();

    expect(storeGateway.bought, ['compounder_ai_monthly']);
    expect(find.text('Compounder AI is active'), findsOneWidget);
    expect(find.textContaining('Requests left today: 17 of 20'), findsOneWidget);
    expect(find.text('Manage subscription'), findsOneWidget);
    expect(store.aiSource, AiSource.compounder);
    expect(store.gatewayApiKey, 'gw-key-123');
  });

  testWidgets('a pending purchase shows the waiting state', (tester) async {
    storeGateway.products = const [_monthly];
    storeGateway.purchaseEvent = const PurchaseEvent(
      outcome: PurchaseOutcome.pending,
      productId: 'compounder_ai_monthly',
    );
    await pumpScreen(tester);

    await tester.tap(find.text('Subscribe'));
    // The pending state shows an indeterminate progress bar, so settle would
    // never finish; pump a few frames instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Waiting for the store'), findsOneWidget);
  });

  testWidgets('a failed verification shows an actionable error', (tester) async {
    storeGateway.products = const [_monthly];
    storeGateway.purchaseEvent = const PurchaseEvent(
      outcome: PurchaseOutcome.purchased,
      productId: 'compounder_ai_monthly',
      token: 'play-token-abc',
    );
    gateway.verifyError = const GatewayException(
        "Can't reach Compounder AI. Check your connection.",
        unreachable: true);
    await pumpScreen(tester);

    await tester.tap(find.text('Subscribe'));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.textContaining("Can't reach Compounder AI"), findsOneWidget);
    expect(find.text('Restore purchases'), findsOneWidget);
  });
}
