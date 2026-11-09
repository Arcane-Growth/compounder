import 'entitlement.dart';
import 'store_gateway.dart';

/// What the subscription screen is showing.
///
/// The states are explicit so every branch (loading, store unavailable,
/// available, pending, purchased, error) has a defined rendering and can be
/// unit-tested without a store or a network.
sealed class SubscriptionState {
  const SubscriptionState();
}

final class SubscriptionLoading extends SubscriptionState {
  const SubscriptionLoading();
}

/// The store cannot sell anything right now: no Play Store / App Store, no
/// signed-in account, or the products are not live yet.
final class SubscriptionStoreUnavailable extends SubscriptionState {
  final String message;
  const SubscriptionStoreUnavailable(this.message);
}

final class SubscriptionAvailable extends SubscriptionState {
  final List<StoreProduct> products;
  const SubscriptionAvailable(this.products);
}

/// A purchase is in flight or awaiting the store's confirmation.
final class SubscriptionPending extends SubscriptionState {
  final String productId;
  const SubscriptionPending(this.productId);
}

final class SubscriptionPurchased extends SubscriptionState {
  final Entitlement entitlement;
  const SubscriptionPurchased(this.entitlement);
}

final class SubscriptionError extends SubscriptionState {
  final String message;
  const SubscriptionError(this.message);
}

/// Inputs to the state machine. Every transition is a pure function of the
/// current state and one event, so the whole flow can be tested exhaustively.
sealed class SubscriptionEvent {
  const SubscriptionEvent();
}

final class Reload extends SubscriptionEvent {
  const Reload();
}

final class ProductsLoaded extends SubscriptionEvent {
  final List<StoreProduct> products;
  const ProductsLoaded(this.products);
}

final class StoreUnavailable extends SubscriptionEvent {
  final String message;
  const StoreUnavailable(this.message);
}

final class PurchaseStarted extends SubscriptionEvent {
  final String productId;
  const PurchaseStarted(this.productId);
}

final class PurchasePending extends SubscriptionEvent {
  final String productId;
  const PurchasePending(this.productId);
}

final class PurchaseVerified extends SubscriptionEvent {
  final Entitlement entitlement;
  const PurchaseVerified(this.entitlement);
}

final class PurchaseFailed extends SubscriptionEvent {
  final String message;
  const PurchaseFailed(this.message);
}

final class EntitlementRefreshed extends SubscriptionEvent {
  final Entitlement entitlement;
  const EntitlementRefreshed(this.entitlement);
}

/// The subscription state machine.
///
/// Rules that matter:
/// - a purchase only becomes [SubscriptionPurchased] once the gateway has
///   verified it and reports an active entitlement;
/// - a verified-but-inactive entitlement stays [SubscriptionPending] rather
///   than claiming access the gateway will refuse;
/// - an expired entitlement drops back to the product list so the user can
///   renew.
SubscriptionState reduceSubscriptionState(
  SubscriptionState current,
  SubscriptionEvent event, {
  required DateTime now,
}) {
  switch (event) {
    case Reload():
      return const SubscriptionLoading();
    case ProductsLoaded(:final products):
      return products.isEmpty
          ? const SubscriptionStoreUnavailable(
              'Subscriptions are not available yet.')
          : SubscriptionAvailable(products);
    case StoreUnavailable(:final message):
      return SubscriptionStoreUnavailable(message);
    case PurchaseStarted(:final productId):
      return SubscriptionPending(productId);
    case PurchasePending(:final productId):
      return SubscriptionPending(productId);
    case PurchaseVerified(:final entitlement):
      return entitlement.isActiveAt(now)
          ? SubscriptionPurchased(entitlement)
          : SubscriptionPending(entitlement.planCode);
    case PurchaseFailed(:final message):
      return SubscriptionError(message);
    case EntitlementRefreshed(:final entitlement):
      if (entitlement.isActiveAt(now)) return SubscriptionPurchased(entitlement);
      final products = _productsOf(current);
      return products == null
          ? const SubscriptionLoading()
          : SubscriptionAvailable(products);
  }
}

List<StoreProduct>? _productsOf(SubscriptionState state) => switch (state) {
      SubscriptionAvailable(:final products) => products,
      _ => null,
    };
