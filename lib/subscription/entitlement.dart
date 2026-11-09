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
enum EntitlementStatus { none, active, trialing, pending, expired, unknown }

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
  final Quota? quota;
  final DateTime? fetchedAt;

  const Entitlement({
    this.status = EntitlementStatus.none,
    this.planCode = '',
    this.currentPeriodEnd,
    this.quota,
    this.fetchedAt,
  });

  /// Whether the entitlement grants access at [now]. A trial grants access
  /// while it runs, so [EntitlementStatus.trialing] counts. A known period end
  /// that has passed means the cached entitlement is stale even if the gateway
  /// last said "active" or "trialing".
  bool isActiveAt(DateTime now) {
    if (status != EntitlementStatus.active &&
        status != EntitlementStatus.trialing) {
      return false;
    }
    final end = currentPeriodEnd;
    return end == null || end.isAfter(now);
  }

  /// True while this entitlement is a free trial rather than a paid plan.
  bool get isTrialing => status == EntitlementStatus.trialing;

  Entitlement copyWith({Quota? quota}) => Entitlement(
        status: status,
        planCode: planCode,
        currentPeriodEnd: currentPeriodEnd,
        quota: quota ?? this.quota,
        fetchedAt: fetchedAt,
      );

  Map<String, Object?> toJson() => {
        'status': status.name,
        'plan_code': planCode,
        if (currentPeriodEnd != null)
          'current_period_end': currentPeriodEnd!.toUtc().toIso8601String(),
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
      return EntitlementStatus.active;
    case 'trialing':
      return EntitlementStatus.trialing;
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
