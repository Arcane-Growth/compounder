import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/models.dart';

class ToolCall {
  final String id;
  final String name;
  final String arguments;
  const ToolCall(this.id, this.name, this.arguments);
}

class ChatMessage {
  static const roleSystem = 'system';
  static const roleUser = 'user';
  static const roleAssistant = 'assistant';
  static const roleTool = 'tool';

  final String role;
  final String? content;
  final String? toolCallId;
  final List<ToolCall> toolCalls;

  /// Multimodal content parts (text + image_url blocks) for user messages
  /// carrying attachments. Takes precedence over [content] when present.
  final List<Map<String, Object?>> parts;

  const ChatMessage(this.role,
      {this.content, this.toolCallId, this.toolCalls = const [], this.parts = const []});

  factory ChatMessage.system(String content) => ChatMessage(roleSystem, content: content);
  factory ChatMessage.user(String content) => ChatMessage(roleUser, content: content);
  factory ChatMessage.userWithParts(String text, List<String> imageDataUrls) => ChatMessage(
        roleUser,
        parts: [
          if (text.isNotEmpty) {'type': 'text', 'text': text},
          for (final url in imageDataUrls) {'type': 'image_url', 'image_url': {'url': url}},
        ],
      );
  factory ChatMessage.assistant(String? content, [List<ToolCall> calls = const []]) =>
      ChatMessage(roleAssistant, content: content, toolCalls: calls);
  factory ChatMessage.tool(String id, String content) => ChatMessage(roleTool, content: content, toolCallId: id);

  Map<String, Object?> toWire() => {
        'role': role,
        if (parts.isNotEmpty) 'content': parts else if (content != null) 'content': content,
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (toolCalls.isNotEmpty)
          'tool_calls': toolCalls
              .map((c) => {
                    'id': c.id,
                    'type': 'function',
                    'function': {'name': c.name, 'arguments': c.arguments},
                  })
              .toList(),
      };
}

class ChatResult {
  final String? content;
  final List<ToolCall> toolCalls;
  const ChatResult(this.content, this.toolCalls);
}

class ToolSpec {
  final String name;
  final String description;
  final Map<String, Object?> parameters;
  const ToolSpec(this.name, this.description, this.parameters);

  Map<String, Object?> toWire() => {
        'type': 'function',
        'function': {'name': name, 'description': description, 'parameters': parameters},
      };
}

/// OpenAI-compatible chat client with tool calling. Points at whatever
/// endpoint the user configures — nothing else ever receives their data.
class ChatClient {
  final String baseUrl;
  final String apiKey;
  final String model;
  final http.Client _http;

  ChatClient(this.baseUrl, this.apiKey, this.model, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Future<ChatResult> chat(List<ChatMessage> messages, List<ToolSpec> tools) async {
    final resp = await _http
        .post(
          Uri.parse('${trimSlash(baseUrl)}/chat/completions'),
          headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model,
            'messages': messages.map((m) => m.toWire()).toList(),
            if (tools.isNotEmpty) 'tools': tools.map((t) => t.toWire()).toList(),
            'tool_choice': 'auto',
          }),
        )
        .timeout(const Duration(seconds: 120));
    if (resp.statusCode != 200) {
      throw Exception('Chat request failed (${resp.statusCode}): ${resp.body.substring(0, resp.body.length.clamp(0, 300))}');
    }
    final choice = (jsonDecode(resp.body)['choices'] as List?)?.first as Map<String, Object?>?;
    if (choice == null) throw Exception('No choices in chat response');
    final message = choice['message'] as Map<String, Object?>;
    return ChatResult(
      message['content'] as String?,
      ((message['tool_calls'] as List?) ?? [])
          .map((c) => ToolCall(
                c['id'] as String,
                (c['function'] as Map)['name'] as String,
                (c['function'] as Map)['arguments'] as String,
              ))
          .toList(),
    );
  }

  Future<String> simple(String system, String user) async {
    final result = await chat([ChatMessage.system(system), ChatMessage.user(user)], const []);
    return result.content?.trim() ?? '';
  }
}

String trimSlash(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;

// ------------------------------------------------------------ vision

class Draft {
  final String dish;
  final List<Food> foods;
  final double calories, protein, carbs, fat;
  const Draft(this.dish, this.foods, this.calories, this.protein, this.carbs, this.fat);
}

/// Photo → nutrition draft using the user's vision-capable endpoint.
Future<Draft> analyzeMealPhoto(ChatClient client, List<int> imageBytes, String mime, List<Meal> recent) async {
  final historyText = recent
      .take(12)
      .map((m) => "- '${m.dish}': ${m.calories.round()} kcal, P ${m.protein.round()}g, C ${m.carbs.round()}g, F ${m.fat.round()}g")
      .join('\n');

  final system = StringBuffer()
    ..write('You are a nutrition analysis assistant. Given a photo of food, respond with ONLY a valid JSON object '
        'matching this exact schema (no markdown fences, no commentary): '
        '{"dish":"short meal name","foods":[{"name":"...","grams":N,"calories":N,"protein":N,"carbs":N,"fat":N}],'
        '"total":{"calories":N,"protein":N,"carbs":N,"fat":N}}.');
  if (historyText.isNotEmpty) {
    system.write(' These are meals the user has logged before (dish and macros) - if the photo matches one, reuse it or note the similarity:\n$historyText');
  }
  system.write(' Protein/carbs/fat are in grams, calories in kcal. Cover every visible component with a best-estimate portion weight.');

  final resp = await client._http
      .post(
        Uri.parse('${trimSlash(client.baseUrl)}/chat/completions'),
        headers: {'Authorization': 'Bearer ${client.apiKey}', 'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': client.model,
          'messages': [
            {'role': 'system', 'content': system.toString()},
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'Analyze the nutrients of the food in this photo.'},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:$mime;base64,${base64Encode(imageBytes)}'}
                },
              ]
            },
          ],
        }),
      )
      .timeout(const Duration(seconds: 120));
  if (resp.statusCode != 200) {
    throw Exception('Vision request failed (${resp.statusCode})');
  }
  final content = ((jsonDecode(resp.body)['choices'] as List?)?.first['message']['content'] as String?) ?? '';
  return parseDraft(content);
}

Draft parseDraft(String content) {
  var cleaned = content.trim();
  if (cleaned.startsWith('```json')) cleaned = cleaned.substring(7);
  if (cleaned.startsWith('```')) cleaned = cleaned.substring(3);
  if (cleaned.endsWith('```')) cleaned = cleaned.substring(0, cleaned.length - 3);
  final json = jsonDecode(cleaned.trim()) as Map<String, Object?>;
  final total = (json['total'] as Map<String, Object?>?) ?? {};
  num n(Object? v) => v is num ? v : 0;
  return Draft(
    (json['dish'] as String?) ?? 'Meal',
    ((json['foods'] as List?) ?? [])
        .map((f) => Food.fromJson((f as Map).cast<String, Object?>()))
        .toList(),
    n(total['calories']).toDouble(),
    n(total['protein']).toDouble(),
    n(total['carbs']).toDouble(),
    n(total['fat']).toDouble(),
  );
}
