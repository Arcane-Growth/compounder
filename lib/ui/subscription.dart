import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../subscription/constants.dart';
import '../subscription/entitlement.dart';
import '../subscription/service.dart';
import '../subscription/state.dart';
import '../subscription/store_gateway.dart';
import 'widgets.dart';

/// One-line entitlement status for Settings.
///
/// A trial is access without a completed purchase, so it says
/// `Trial · ends <date>` and never `Active · renews`. The date comes from the
/// gateway/store; the trial length is never assumed here.
String entitlementSummary(Entitlement? entitlement, DateTime now) {
  if (entitlement == null || !entitlement.isActiveAt(now)) {
    return 'Not active — subscribe or restore a purchase.';
  }
  final end = entitlement.currentPeriodEnd;
  if (entitlement.isPastDue) {
    // The stored period end is already in the past for a past-due
    // subscription; the grace end is the date that matters.
    return _pastDueCopy(entitlement.graceEndsAt!);
  }
  if (entitlement.isTrialing) {
    return end == null
        ? 'Trial'
        : 'Trial · ends ${formatDate(end.millisecondsSinceEpoch)}';
  }
  return end == null
      ? 'Active'
      : 'Active · renews ${formatDate(end.millisecondsSinceEpoch)}';
}

/// Copy for a past-due subscription that still has access.
///
/// Only reached for an entitlement [Entitlement.isActiveAt] reports as active,
/// which for [EntitlementStatus.pastDue] requires a non-null grace end in the
/// future — so [graceEnd] is always set here. There is deliberately no
/// "access continues" fallback: a past-due entitlement without a grace end is
/// not active and renders as "Not active" instead.
String _pastDueCopy(DateTime graceEnd) =>
    'Payment failed — access ends ${formatDate(graceEnd.millisecondsSinceEpoch)}';

/// Compounder AI subscription: plans, purchase, restore and manage.
///
/// Prices always come from the store; the screen never hardcodes one. Every
/// state the purchase flow can be in has an explicit rendering, including the
/// store being unavailable (the normal state until the products are live).
class SubscriptionScreen extends StatefulWidget {
  final SubscriptionService service;

  const SubscriptionScreen({super.key, required this.service});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  @override
  void initState() {
    super.initState();
    widget.service.load();
  }

  Future<void> _manage() async {
    final url = defaultTargetPlatform == TargetPlatform.iOS
        ? manageSubscriptionUrlIos
        : manageSubscriptionUrlAndroid;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the store page.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Compounder AI')),
      body: ListenableBuilder(
        listenable: widget.service,
        builder: (context, _) {
          final state = widget.service.state;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SectionHeader('Subscription'),
              const SizedBox(height: 8),
              Card(
                color: scheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Compounder AI runs on our gateway, so the coach and meal '
                    'photo analysis work without your own API key. Requests '
                    'are sent only to the gateway.',
                    style:
                        t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ..._body(state, scheme, t),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Prices are set by the store and may vary by region.',
                  style:
                      t.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _body(SubscriptionState state, ColorScheme scheme, TextTheme t) {
    switch (state) {
      case SubscriptionLoading():
        return [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
          Center(
            child: Text('Checking the store…',
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ];
      case SubscriptionStoreUnavailable(:final message):
        return [
          _StateCard(
            icon: Icons.storefront_outlined,
            title: 'Store unavailable',
            message: message,
            action: OutlinedButton(
              onPressed: widget.service.load,
              child: const Text('Try again'),
            ),
          ),
        ];
      case SubscriptionAvailable(:final products):
        return [
          for (final product in products) ...[
            _PlanCard(
              product: product,
              onSubscribe: () => widget.service.buy(product.id),
            ),
            const SizedBox(height: 12),
          ],
          _RestoreRow(
            onRestore: widget.service.restore,
            onManage: _manage,
          ),
        ];
      case SubscriptionPending(:final productId):
        return [
          _StateCard(
            icon: Icons.hourglass_top,
            title: 'Waiting for the store',
            message:
                'The store is confirming your ${subscriptionPlanLabels[productId] ?? 'plan'} '
                'purchase. This can take a moment.',
            action: const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          ),
        ];
      case SubscriptionPurchased(:final entitlement):
        return [
          _PurchasedCard(
            entitlement: entitlement,
            onManage: _manage,
            onRestore: widget.service.restore,
          ),
        ];
      case SubscriptionError(:final message):
        return [
          _StateCard(
            icon: Icons.error_outline,
            title: 'Something went wrong',
            message: message,
            action: Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(
                onPressed: widget.service.load,
                child: const Text('Try again'),
              ),
              TextButton(
                onPressed: widget.service.restore,
                child: const Text('Restore purchases'),
              ),
            ]),
          ),
        ];
    }
  }
}

class _PlanCard extends StatelessWidget {
  final StoreProduct product;
  final VoidCallback onSubscribe;

  const _PlanCard({required this.product, required this.onSubscribe});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final label = subscriptionPlanLabels[product.id] ?? product.title;
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: t.titleMedium),
                const SizedBox(height: 4),
                Text(product.price,
                    style: t.titleLarge?.copyWith(color: scheme.primary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: onSubscribe,
            child: const Text('Subscribe'),
          ),
        ]),
      ),
    );
  }
}

class _PurchasedCard extends StatelessWidget {
  final Entitlement entitlement;
  final VoidCallback onManage;
  final VoidCallback onRestore;

  const _PurchasedCard({
    required this.entitlement,
    required this.onManage,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final quota = entitlement.quota;
    final end = entitlement.currentPeriodEnd;
    // A trial is access without a completed purchase: it gets its own copy and
    // never claims a renewal date. The end date comes from the gateway/store,
    // so the trial length is never hardcoded here.
    final trialing = entitlement.isTrialing;
    // A past-due subscription is still inside the gateway's grace window, so it
    // keeps access but must say the payment failed and must not claim a
    // renewal date (the stored period end is already in the past).
    final pastDue = entitlement.isPastDue;
    final title = _purchasedTitle(entitlement);
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(_purchasedIcon(entitlement), color: scheme.primary, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title, style: t.titleMedium),
            ),
          ]),
          const SizedBox(height: 8),
          if (entitlement.planCode.isNotEmpty)
            Text('Plan: ${entitlement.planCode}', style: t.bodyMedium),
          if (!trialing && !pastDue && end != null)
            Text('Renews: ${formatDate(end.millisecondsSinceEpoch)}',
                style: t.bodyMedium),
          if (quota != null)
            Text(
                'Requests left today: ${quota.dailyRemaining} of ${quota.dailyLimit}',
                style: t.bodyMedium),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(
              onPressed: onManage,
              child: const Text('Manage subscription'),
            ),
            TextButton(
              onPressed: onRestore,
              child: const Text('Restore purchases'),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Title for the purchased card.
///
/// A trial is access without a completed purchase, so it never claims a
/// renewal date; a past-due subscription keeps access but must say the payment
/// failed. Both dates come from the gateway/store, never from a hardcoded
/// trial length.
String _purchasedTitle(Entitlement entitlement) {
  if (entitlement.isPastDue) return _pastDueCopy(entitlement.graceEndsAt!);
  if (entitlement.isTrialing) {
    final end = entitlement.currentPeriodEnd;
    return end == null
        ? 'Trial'
        : 'Trial — ends ${formatDate(end.millisecondsSinceEpoch)}';
  }
  return 'Compounder AI is active';
}

IconData _purchasedIcon(Entitlement entitlement) {
  if (entitlement.isPastDue) return Icons.warning_amber;
  if (entitlement.isTrialing) return Icons.timelapse;
  return Icons.check_circle;
}

class _RestoreRow extends StatelessWidget {
  final VoidCallback onRestore;
  final VoidCallback onManage;

  const _RestoreRow({required this.onRestore, required this.onManage});

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: [
      OutlinedButton(
        onPressed: onRestore,
        child: const Text('Restore purchases'),
      ),
      TextButton(
        onPressed: onManage,
        child: const Text('Manage subscription'),
      ),
    ]);
  }
}

class _StateCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const _StateCard({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: scheme.primary, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: t.titleMedium)),
          ]),
          const SizedBox(height: 8),
          Text(message,
              style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          if (action != null) ...[
            const SizedBox(height: 12),
            action!,
          ],
        ]),
      ),
    );
  }
}
