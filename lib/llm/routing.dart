import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../data/store.dart';
import '../subscription/constants.dart';
import '../subscription/entitlement.dart';
import 'llm.dart';

/// Builds the chat client for the source the user selected.
///
/// [AiSource.byo] is the original behaviour and stays free and unlimited.
/// [AiSource.compounder] points at the gateway with the API key issued after a
/// verified store purchase.
ChatClient chatClientFor(AppStore store) {
  if (store.aiSource == AiSource.compounder) {
    return ChatClient(
        gatewayChatBaseUrl, store.gatewayApiKey ?? '', compounderAiModel);
  }
  final ai = store.ai;
  return ChatClient(ai.baseUrl, ai.apiKey, ai.model);
}

/// Whether the selected source has everything it needs to make a call.
bool aiConfigured(AppStore store) {
  if (store.aiSource == AiSource.compounder) {
    return (store.gatewayApiKey ?? '').isNotEmpty;
  }
  return store.ai.configured;
}

/// Copy shown when the selected source is not usable yet.
String aiNotConfiguredMessage(AiSource source) => source == AiSource.compounder
    ? 'Compounder AI is not active yet. Open Settings → Compounder AI to '
        'subscribe or restore a purchase.'
    : 'Set your AI endpoint and key in Settings before using the coach.';

/// Turns a failed AI call into one sentence the user can act on.
///
/// A quota rejection is never shown as a raw error: it names the limit and
/// points at the subscription screen. Offline failures say the gateway could
/// not be reached rather than leaking a socket exception.
String friendlyAiError(Object error, AiSource source) {
  final paid = source == AiSource.compounder;
  if (error is ChatHttpException) {
    if (error.quotaExceeded) {
      return paid
          ? "You've used today's Compounder AI requests. Manage your "
              'subscription in Settings, or switch to your own endpoint.'
          : 'Your endpoint is rate-limiting requests. Try again in a moment.';
    }
    if (error.statusCode == 401 || error.statusCode == 403) {
      return paid
          ? 'Compounder AI rejected the API key. Restore your purchase in '
              'Settings.'
          : 'Your endpoint rejected the API token. Check it in Settings.';
    }
    return paid
        ? 'Compounder AI could not answer that request. Try again.'
        : 'Your AI endpoint returned an error (${error.statusCode}).';
  }
  if (error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException) {
    return paid
        ? "Can't reach Compounder AI. Check your connection — your cached "
            'plan is still shown in Settings.'
        : "Can't reach your AI endpoint. Check the URL and your connection.";
  }
  return paid
      ? 'Compounder AI could not answer that request. Try again.'
      : 'The AI request failed. Check your endpoint in Settings.';
}
