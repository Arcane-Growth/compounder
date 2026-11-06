import 'dart:convert';

import 'package:compounder/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _draft = jsonEncode({
  'choices': [
    {
      'message': {
        'content': jsonEncode({
          'dish': 'Toast',
          'foods': [],
          'total': {'calories': 90, 'protein': 3, 'carbs': 15, 'fat': 1},
        }),
      },
    },
  ],
});

/// Runs the vision call against a stubbed endpoint and returns the text part of
/// the user message the model would have received.
Future<String> _sentPrompt({String? note}) async {
  late Map<String, Object?> body;
  final client = ChatClient(
    'http://localhost/v1',
    'test-key',
    'test-model',
    httpClient: MockClient((request) async {
      body = jsonDecode(request.body) as Map<String, Object?>;
      return http.Response(_draft, 200);
    }),
  );

  final draft = await analyzeMealPhoto(
    client,
    const [1, 2, 3],
    'image/jpeg',
    const [],
    note: note,
  );
  expect(draft.dish, 'Toast');

  final messages = body['messages'] as List;
  final userParts = (messages[1] as Map)['content'] as List;
  return (userParts.first as Map)['text'] as String;
}

void main() {
  group('meal photo prompt', () {
    test('keeps the original prompt when no note is given', () async {
      expect(await _sentPrompt(),
          'Analyze the nutrients of the food in this photo.');
    });

    test('appends a user description to the prompt', () async {
      final prompt = await _sentPrompt(note: 'two slices, extra cheese');
      expect(prompt, contains('Analyze the nutrients of the food in this photo.'));
      expect(prompt, contains('The user describes it as: two slices, extra cheese'));
    });

    test('ignores a blank note', () async {
      expect(await _sentPrompt(note: '   '),
          'Analyze the nutrients of the food in this photo.');
    });
  });
}
