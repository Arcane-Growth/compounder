import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// A subscription product as the store describes it.
///
/// [price] is the store's own formatted price string (with currency symbol);
/// the app never hardcodes a price.
class StoreProduct {
  final String id;
  final String title;
  final String price;
  final double rawPrice;
  final String currencyCode;

  const StoreProduct({
    required this.id,
    required this.title,
    required this.price,
    required this.rawPrice,
    required this.currencyCode,
  });
}

enum PurchaseOutcome { purchased, restored, pending, canceled, error }

/// One purchase-stream event, normalised away from the plugin types so the
/// subscription service can be tested without a store.
class PurchaseEvent {
  final PurchaseOutcome outcome;
  final String productId;

  /// Google Play purchase token, or the App Store transaction id.
  final String? token;
  final String? transactionId;
  final String? error;

  /// Opaque handle the store needs back to acknowledge the purchase.
  final Object? handle;

  const PurchaseEvent({
    required this.outcome,
    required this.productId,
    this.token,
    this.transactionId,
    this.error,
    this.handle,
  });
}

/// The store side of the subscription: product lookup, purchase, restore and
/// the purchase stream. Abstract so tests can drive a fake store.
abstract class StoreGateway {
  Future<bool> isAvailable();

  /// Returns the products the store knows about. Unknown ids are simply absent
  /// from the result — that is the normal state until the products are live in
  /// Play Console / App Store Connect.
  Future<List<StoreProduct>> queryProducts(List<String> ids);

  Stream<PurchaseEvent> get events;

  Future<void> buy(StoreProduct product);

  Future<void> restore();

  /// Acknowledges a purchase once the gateway has verified it. Until this is
  /// called Google Play refunds the purchase after three days.
  Future<void> complete(PurchaseEvent event);

  Future<void> dispose();
}

/// [StoreGateway] backed by `in_app_purchase` (Play Billing / StoreKit).
class InAppPurchaseStoreGateway implements StoreGateway {
  final InAppPurchase _iap;
  final Map<String, ProductDetails> _details = {};
  final StreamController<PurchaseEvent> _events =
      StreamController<PurchaseEvent>.broadcast();
  StreamSubscription<List<PurchaseDetails>>? _subscription;

  InAppPurchaseStoreGateway({InAppPurchase? iap})
      : _iap = iap ?? InAppPurchase.instance {
    _subscription = _iap.purchaseStream.listen(_onPurchases);
  }

  @override
  Future<bool> isAvailable() async {
    try {
      return await _iap.isAvailable();
    } catch (_) {
      // No Play Store / App Store on this device (or no signed-in account).
      return false;
    }
  }

  @override
  Future<List<StoreProduct>> queryProducts(List<String> ids) async {
    final response = await _iap.queryProductDetails(ids.toSet());
    if (response.error != null) return const [];
    _details
      ..clear()
      ..addEntries(response.productDetails.map((p) => MapEntry(p.id, p)));
    return response.productDetails
        .map((p) => StoreProduct(
              id: p.id,
              title: p.title,
              price: p.price,
              rawPrice: p.rawPrice,
              currencyCode: p.currencyCode,
            ))
        .toList();
  }

  @override
  Stream<PurchaseEvent> get events => _events.stream;

  @override
  Future<void> buy(StoreProduct product) async {
    final details = _details[product.id];
    if (details == null) {
      throw StateError('Product ${product.id} was not loaded from the store');
    }
    // Subscriptions are non-consumable: they are acknowledged, never consumed.
    await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: details));
  }

  @override
  Future<void> restore() => _iap.restorePurchases();

  @override
  Future<void> complete(PurchaseEvent event) async {
    final handle = event.handle;
    if (handle is PurchaseDetails) {
      await _iap.completePurchase(handle);
    }
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _events.close();
  }

  void _onPurchases(List<PurchaseDetails> purchases) {
    for (final purchase in purchases) {
      final event = _map(purchase);
      if (event != null && !_events.isClosed) _events.add(event);
    }
  }

  PurchaseEvent? _map(PurchaseDetails purchase) {
    final isApple = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final token = purchase.verificationData.serverVerificationData;
    switch (purchase.status) {
      case PurchaseStatus.purchased:
        return PurchaseEvent(
          outcome: PurchaseOutcome.purchased,
          productId: purchase.productID,
          token: token,
          transactionId: isApple ? purchase.purchaseID : null,
          handle: purchase,
        );
      case PurchaseStatus.restored:
        return PurchaseEvent(
          outcome: PurchaseOutcome.restored,
          productId: purchase.productID,
          token: token,
          transactionId: isApple ? purchase.purchaseID : null,
          handle: purchase,
        );
      case PurchaseStatus.pending:
        return PurchaseEvent(
          outcome: PurchaseOutcome.pending,
          productId: purchase.productID,
          handle: purchase,
        );
      case PurchaseStatus.canceled:
        return PurchaseEvent(
          outcome: PurchaseOutcome.canceled,
          productId: purchase.productID,
          handle: purchase,
        );
      case PurchaseStatus.error:
        return PurchaseEvent(
          outcome: PurchaseOutcome.error,
          productId: purchase.productID,
          error: purchase.error?.message ?? 'The store rejected the purchase.',
          handle: purchase,
        );
    }
  }
}
