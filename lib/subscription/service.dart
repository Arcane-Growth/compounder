import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/store.dart';
import 'constants.dart';
import 'entitlement.dart';
import 'gateway.dart';
import 'secrets.dart';
import 'state.dart';
import 'store_gateway.dart';

/// Owns the Compounder AI subscription: product lookup, purchase, gateway
/// verification, restore, and the cached entitlement.
///
/// The store, the gateway and the secret store are injected so the whole flow
/// can be driven by fakes in tests.
class SubscriptionService extends ChangeNotifier {
  final AppStore store;
  final StoreGateway storeGateway;
  final GatewayClient gateway;
  final SecretStore secrets;
  final DateTime Function() now;
  final Duration restoreTimeout;

  SubscriptionState _state = const SubscriptionLoading();
  SubscriptionState get state => _state;

  StreamSubscription<PurchaseEvent>? _events;
  Completer<bool>? _restoreWait;
  bool _initialised = false;
  bool _disposed = false;

  /// The last product list the store returned, so cancelling the store sheet
  /// returns to the plans instead of an empty loading screen.
  List<StoreProduct> _lastProducts = const [];

  SubscriptionService({
    required this.store,
    required this.storeGateway,
    required this.gateway,
    required this.secrets,
    DateTime Function()? now,
    this.restoreTimeout = const Duration(seconds: 8),
  }) : now = now ?? DateTime.now;

  /// Loads the cached API key and starts listening to the store's purchase
  /// stream. Safe to call more than once.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    final key = await secrets.read(gatewayApiKeySecret);
    if (key != null && key.isNotEmpty) {
      await store.saveGatewayKey(key);
    }
    _events = storeGateway.events.listen(_onPurchaseEvent);
  }

  /// Loads the subscription screen: cached entitlement first (so an offline
  /// user sees their plan), then the store's products.
  Future<void> load() async {
    await init();
    _set(const SubscriptionLoading());
    final cached = store.entitlement;
    if (cached != null && cached.isActiveAt(now())) {
      _set(SubscriptionPurchased(cached));
      return;
    }
    final available = await storeGateway.isAvailable();
    if (!available) {
      _set(const SubscriptionStoreUnavailable(
          'The store is not available on this device.'));
      return;
    }
    List<StoreProduct> products;
    try {
      products = await storeGateway.queryProducts(subscriptionProductIds);
    } catch (_) {
      products = const [];
    }
    _lastProducts = products;
    _set(reduceSubscriptionState(
        _state, ProductsLoaded(products), now: now()));
  }

  /// Re-reads the entitlement from the gateway. Offline, the cached copy stays
  /// on screen and nothing throws.
  Future<void> refreshEntitlement() async {
    await init();
    final key = store.gatewayApiKey;
    if (key == null || key.isEmpty) return;
    try {
      final result = await gateway.entitlement(key);
      await store.saveEntitlement(result.entitlement);
      _set(reduceSubscriptionState(
          _state, EntitlementRefreshed(result.entitlement), now: now()));
    } on GatewayException {
      // Keep whatever is cached; the UI already says "can't reach".
    }
  }

  /// Starts a purchase. The store's purchase stream drives the rest.
  Future<void> buy(String productId) async {
    await init();
    final current = _state;
    final products = current is SubscriptionAvailable ? current.products : null;
    StoreProduct? product;
    for (final p in products ?? const <StoreProduct>[]) {
      if (p.id == productId) product = p;
    }
    if (product == null) {
      _set(const SubscriptionError('That plan is not available right now.'));
      return;
    }
    _set(reduceSubscriptionState(
        _state, PurchaseStarted(productId), now: now()));
    try {
      await storeGateway.buy(product);
    } catch (_) {
      _set(const SubscriptionError('The store could not start the purchase.'));
    }
  }

  /// Restores a previous purchase: first through the store (which replays the
  /// purchase stream), then through the gateway if the store has nothing.
  Future<void> restore() async {
    await init();
    _set(const SubscriptionLoading());
    final wait = Completer<bool>();
    _restoreWait = wait;
    try {
      await storeGateway.restore();
    } catch (_) {
      // Fall through to the gateway restore below.
    }
    final restored = await wait.future
        .timeout(restoreTimeout, onTimeout: () => false);
    if (restored) return;
    try {
      final deviceToken = await _deviceToken();
      final result = await gateway.restore(
          apiKey: store.gatewayApiKey, deviceToken: deviceToken);
      if (result.apiKey != null && result.apiKey!.isNotEmpty) {
        await _saveKey(result.apiKey!);
      }
      await store.saveEntitlement(result.entitlement);
      if (result.entitlement.isActiveAt(now())) {
        await store.setAiSource(AiSource.compounder);
        _set(reduceSubscriptionState(
            _state, EntitlementRefreshed(result.entitlement), now: now()));
      } else {
        _set(const SubscriptionError(
            'No previous Compounder AI purchase was found for this device.'));
      }
    } on GatewayException catch (e) {
      _set(SubscriptionError(e.message));
    }
  }

  /// Switches the coach between the paid gateway and the user's own endpoint.
  Future<void> setSource(AiSource source) async {
    await store.setAiSource(source);
    notifyListeners();
  }

  void _onPurchaseEvent(PurchaseEvent event) {
    switch (event.outcome) {
      case PurchaseOutcome.purchased:
      case PurchaseOutcome.restored:
        unawaited(_verify(event));
      case PurchaseOutcome.pending:
        _set(reduceSubscriptionState(
            _state, PurchasePending(event.productId), now: now()));
      case PurchaseOutcome.canceled:
        // The user backed out of the store sheet: not an error. While the
        // sheet is up the state is Pending, so fall back to the plans we
        // already loaded instead of dropping to an empty loading screen.
        final products = _state is SubscriptionAvailable
            ? (_state as SubscriptionAvailable).products
            : _lastProducts;
        _set(products.isEmpty
            ? const SubscriptionLoading()
            : SubscriptionAvailable(products));
      case PurchaseOutcome.error:
        _set(reduceSubscriptionState(
            _state,
            PurchaseFailed(event.error ?? 'The purchase failed.'),
            now: now()));
    }
  }

  Future<void> _verify(PurchaseEvent event) async {
    try {
      final deviceToken = await _deviceToken();
      final GatewayEntitlement result;
      if (event.transactionId != null) {
        result = await gateway.verifyApple(
          productId: event.productId,
          transactionId: event.transactionId!,
          deviceToken: deviceToken,
        );
      } else {
        result = await gateway.verifyGoogle(
          productId: event.productId,
          purchaseToken: event.token ?? '',
          deviceToken: deviceToken,
        );
      }
      if (result.apiKey != null && result.apiKey!.isNotEmpty) {
        await _saveKey(result.apiKey!);
      }
      await store.saveEntitlement(result.entitlement);
      if (result.entitlement.isActiveAt(now())) {
        await store.setAiSource(AiSource.compounder);
      }
      // Only acknowledge once the gateway has accepted the purchase; an
      // unacknowledged Play purchase is refunded after three days, so a failed
      // verification is retried on the next launch instead of being lost.
      await storeGateway.complete(event);
      _set(reduceSubscriptionState(
          _state, PurchaseVerified(result.entitlement), now: now()));
      _completeRestoreWait(true);
    } on GatewayException catch (e) {
      _set(reduceSubscriptionState(
          _state, PurchaseFailed(e.message), now: now()));
      _completeRestoreWait(false);
    }
  }

  void _completeRestoreWait(bool value) {
    final wait = _restoreWait;
    if (wait != null && !wait.isCompleted) wait.complete(value);
    _restoreWait = null;
  }

  Future<String?> _deviceToken() async {
    final cached = store.deviceToken;
    if (cached != null &&
        cached.isNotEmpty &&
        store.deviceTokenRegistered) {
      return cached;
    }
    try {
      // register() mints and persists the token before the request, so a
      // failed attempt retries with the same identity instead of a new one.
      return await gateway.register();
    } on GatewayException {
      // Verification still works without a device token; the gateway can key
      // the account off the purchase itself.
      return null;
    }
  }

  Future<void> _saveKey(String key) async {
    await secrets.write(gatewayApiKeySecret, key);
    await store.saveGatewayKey(key);
  }

  void _set(SubscriptionState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _events?.cancel();
    storeGateway.dispose();
    super.dispose();
  }
}
