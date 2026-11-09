import 'dart:convert';

/// Where the coach and vision calls are sent.
///
/// [byo] is the original behaviour: the user's own OpenAI-compatible endpoint,
/// free and unlimited. [compounder] routes through the gateway with the API key
/// issued after a store purchase.
enum AiSource { byo, compounder }

/// Subscription status as reported by the gateway.
///
/// [trialing] is a distinct state: the trial grants access (quota applies) but
/// it is not a completed purchase, so the UI must never call it "active" or
/// claim a renewal date. [currentPeriodEnd] is the trial end in that case.
///
/// [pastDue] is a documented grace state: the store reported a failed payment
/// and the gateway still grants access until [Entitlement.graceEndsAt]. It is
/// not collapsed into [active] because the UI must say the payment failed and
/// must not claim a renewal date (the stored period end is already in the past).
enum EntitlementStatus { none, active, trialing, pastDue, pending, expired, unknown }

/// Daily request and monthly token allowance attached to an entitlement.
class Quota {
  final int dailyLimit;
  final int dailyUsed;
  final int monthlyTokensLimit;
  final int monthlyTokensUsed;

  const Quota({
    this.dailyLimit = 0,
    this.dailyUsed = 0,
    this.monthlyTokensLimit = 0,
    this.monthlyTokensUsed = 0,
  });

  /// Requests left today, never negative. The gateway is the authority; this
  /// is only what the last response reported.
  int get dailyRemaining {
    final left = dailyLimit - dailyUsed;
    return left < 0 ? 0 : left;
  }

  Map<String, Object?> toJson() => {
        'daily_requests_limit': dailyLimit,
        'daily_requests_used': dailyUsed,
        'monthly_tokens_limit': monthlyTokensLimit,
        'monthly_tokens_used': monthlyTokensUsed,
      };

  factory Quota.fromJson(Map<String, Object?> json) => Quota(
        dailyLimit: _int(json['daily_requests_limit']),
        dailyUsed: _int(json['daily_requests_used']),
        monthlyTokensLimit: _int(json['monthly_tokens_limit']),
        monthlyTokensUsed: _int(json['monthly_tokens_used']),
      );
}

/// A verified Compounder AI entitlement.
///
/// [fetchedAt] is when the gateway last confirmed it; the cached copy is shown
/// offline so the coach can explain why it is not reachable instead of crashing.
class Entitlement {
  final EntitlementStatus status;
  final String planCode;
  final DateTime? currentPeriodEnd;

  /// End of the gateway's grace window for a [EntitlementStatus.pastDue]
  /// entitlement. Null for every other status.
  final DateTime? graceEndsAt;
  final Quota? quota;
  final DateTime? fetchedAt;

  const Entitlement({
    this.status = EntitlementStatus.none,
    this.planCode = '',
    this.currentPeriodEnd,
    this.graceEndsAt,
    this.quota,
    this.fetchedAt,
  });

  /// Whether the entitlement grants access at [now]. A trial grants access
  /// while it runs, so [EntitlementStatus.trialing] counts. A known period end
  /// that has passed means the cached entitlement is stale even if the gateway
  /// last said "active" or "trialing".
  ///
  /// A missing period end is deliberately treated as access, not as expiry.
  /// The gateway is the authority and always sends `current_period_end` for a
  /// trial (and for a paid plan), so a null end means the field was dropped —
  /// an older cache, a partial response — rather than that the trial ended.
  /// Revoking locally on a missing field would push a paying trial user back
  /// to the plans screen and invite a duplicate purchase; the gateway still
  /// refuses requests once the trial really ends. Pinned by
  /// `subscription_state_test.dart` ("a trialing entitlement with no period
  /// end stays active").
  ///
  /// A past-due entitlement is entitled only inside the grace window, exactly
  /// like the gateway's `entitlement_grants_access`: the store's period end is
  /// already in the past, so [graceEndsAt] is the only authority. A missing
  /// grace end means no access, matching the gateway.
  bool isActiveAt(DateTime now) {
    switch (status) {
      case EntitlementStatus.active:
      case EntitlementStatus.trialing:
        final end = currentPeriodEnd;
        return end == null || end.isAfter(now);
      case EntitlementStatus.pastDue:
        final grace = graceEndsAt;
        return grace != null && grace.isAfter(now);
      default:
        return false;
    }
  }

  /// True while this entitlement is a free trial rather than a paid plan.
  bool get isTrialing => status == EntitlementStatus.trialing;

  /// True while the subscription is past due but still inside the grace window.
  bool get isPastDue => status == EntitlementStatus.pastDue;

  Entitlement copyWith({Quota? quota}) => Entitlement(
        status: status,
        planCode: planCode,
        currentPeriodEnd: currentPeriodEnd,
        graceEndsAt: graceEndsAt,
        quota: quota ?? this.quota,
        fetchedAt: fetchedAt,
      );

  Map<String, Object?> toJson() => {
        'status': status.name,
        'plan_code': planCode,
        if (currentPeriodEnd != null)
          'current_period_end': currentPeriodEnd!.toUtc().toIso8601String(),
        if (graceEndsAt != null)
          'grace_ends_at': graceEndsAt!.toUtc().toIso8601String(),
        if (quota != null) 'quota': quota!.toJson(),
        if (fetchedAt != null) 'fetched_at': fetchedAt!.toUtc().toIso8601String(),
      };

  /// Tolerant decode: a cache written by an older build, or a hand-edited
  /// value, must never stop the app from starting.
  factory Entitlement.fromJson(Map<String, Object?> json) {
    final quotaJson = json['quota'];
    return Entitlement(
      status: parseEntitlementStatus(json['status']),
      planCode: json['plan_code'] is String ? json['plan_code'] as String : '',
      currentPeriodEnd: _date(json['current_period_end']),
      graceEndsAt: _date(json['grace_ends_at']),
      quota: quotaJson is Map
          ? Quota.fromJson(quotaJson.cast<String, Object?>())
          : null,
      fetchedAt: _date(json['fetched_at']),
    );
  }

  /// Decodes the cached entitlement blob, or null when absent/corrupt.
  static Entitlement? decodeCache(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Entitlement.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  String encodeCache() => jsonEncode(toJson());
}

/// Maps the gateway's status string onto [EntitlementStatus].
///
/// Unknown values are [EntitlementStatus.unknown] rather than "none" so a new
/// server-side state does not silently revoke access.
EntitlementStatus parseEntitlementStatus(Object? raw) {
  final value = raw is String ? raw.trim().toLowerCase() : '';
  switch (value) {
    case 'active':
    case 'grace_period':
    // The gateway treats a free entitlement as entitled
    // (entitlement_grants_access), so the app must not revoke it.
    case 'free':
      return EntitlementStatus.active;
    case 'trialing':
      return EntitlementStatus.trialing;
    case 'past_due':
    // The cache stores the enum name, which has no underscore.
    case 'pastdue':
      return EntitlementStatus.pastDue;
    case 'pending':
    case 'incomplete':
      return EntitlementStatus.pending;
    case 'expired':
    case 'canceled':
    case 'cancelled':
    case 'none':
    case 'inactive':
      return EntitlementStatus.none;
    default:
      return EntitlementStatus.unknown;
  }
}

/// Parses a period end from either an RFC 3339 string or an epoch number.
///
/// The gateway contract does not pin the encoding, so both are accepted. A
/// number below 1e11 is treated as seconds (it would otherwise be a date in
/// 1970); anything larger is milliseconds.
DateTime? _date(Object? raw) {
  if (raw is String) return DateTime.tryParse(raw)?.toLocal();
  if (raw is num) {
    final value = raw.toInt();
    if (value <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
            value < 100000000000 ? value * 1000 : value)
        .toLocal();
  }
  return null;
}

int _int(Object? raw) => raw is num ? raw.toInt() : 0;
