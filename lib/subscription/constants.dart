/// Every store product id, gateway URL and plan constant lives here.
///
/// Nothing else in the app may hardcode a product id or a price: prices are
/// always read from the store (Google Play / App Store) at runtime, so a price
/// change in the console needs no app release.
library;

/// Gateway that verifies store purchases and serves Compounder AI.
const String gatewayBaseUrl = 'https://gateway.arcanegrowth.com';

/// OpenAI-compatible chat endpoint on the gateway.
const String gatewayChatBaseUrl = '$gatewayBaseUrl/v1';

/// Model name sent to the gateway. The gateway maps it to the model it serves
/// for Compounder AI; the app never picks a model for subscription users.
const String compounderAiModel = 'compounder-ai';

/// Google Play / App Store subscription product ids.
///
/// These must match the products created in Play Console and App Store
/// Connect. They are the only place the ids appear.
const String productMonthly = 'compounder_ai_monthly';
const String productAnnual = 'compounder_ai_annual';

/// Products shown on the subscription screen, in display order.
const List<String> subscriptionProductIds = [productMonthly, productAnnual];

/// Human labels for the two plans. Prices are never part of these.
const Map<String, String> subscriptionPlanLabels = {
  productMonthly: 'Monthly',
  productAnnual: 'Annual',
};

/// Store pages where a subscription can be managed or cancelled. There is no
/// in-app billing UI for cancellation, so the screen deep-links to the store.
const String manageSubscriptionUrlAndroid =
    'https://play.google.com/store/account/subscriptions'
    '?package=com.arcanegrowth.compounder';
const String manageSubscriptionUrlIos =
    'https://apps.apple.com/account/subscriptions';

/// SharedPreferences keys owned by the subscription feature.
const String prefAiSource = 'aiSource';
const String prefEntitlement = 'entitlement';
const String prefDeviceToken = 'gatewayDeviceToken';

/// Whether the gateway accepted [prefDeviceToken]. A token that was persisted
/// but never confirmed must be registered again before it can authenticate.
const String prefDeviceTokenRegistered = 'gatewayDeviceTokenRegistered';

/// Value stored in [prefAiSource] for the paid gateway. Anything else (or
/// nothing at all) means bring-your-own-endpoint, which is the pre-existing
/// behaviour and stays free and unlimited.
const String aiSourceCompounder = 'compounder';
