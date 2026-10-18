import 'dart:convert';

import 'package:http/http.dart' as http;

/// Minimal Claude Messages API client with a tool-use loop.
///
/// Dart has no official Anthropic SDK, so this talks to the REST API
/// directly. The conversation history is append-only: assistant turns are
/// stored with their full `content` (including thinking blocks) and never
/// edited, which the API requires for thinking to stay valid across turns.
class ClaudeClient {
  final String apiKey;
  final String model;
  final http.Client _http;
  static final _endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  /// Start a fresh conversation after this many messages instead of
  /// trimming old ones (trimming would edit history).
  static const maxHistory = 60;

  final List<Map<String, dynamic>> _messages = [];

  ClaudeClient({required this.apiKey, required this.model, http.Client? client})
      : _http = client ?? http.Client();

  List<Map<String, dynamic>> get history => List.unmodifiable(_messages);

  void reset() => _messages.clear();

  /// Sends [userText], runs any tool calls through [runTool], and returns
  /// Claude's final spoken reply.
  Future<String> ask(
    String userText, {
    required String system,
    required List<Map<String, dynamic>> tools,
    required Future<String> Function(String name, Map<String, dynamic> input)
        runTool,
    int maxToolRounds = 5,
  }) async {
    if (_messages.length >= maxHistory) reset();
    final checkpoint = _messages.length;
    _messages.add({'role': 'user', 'content': userText});

    try {
      for (var round = 0; round <= maxToolRounds; round++) {
        final res = await _send(system: system, tools: tools);
        final stop = res['stop_reason'] as String?;
        final content = (res['content'] as List).cast<Map<String, dynamic>>();

        if (stop == 'refusal') {
          // Leave the refused turn out of history and reply politely.
          _messages.removeRange(checkpoint, _messages.length);
          return "I'm afraid I can't help with that one.";
        }

        _messages.add({'role': 'assistant', 'content': content});

        if (stop != 'tool_use') {
          return content
              .where((b) => b['type'] == 'text')
              .map((b) => b['text'] as String)
              .join(' ')
              .trim();
        }

        // Run every requested tool and return all results in one message.
        final calls = content.where((b) => b['type'] == 'tool_use').toList();
        final results = await Future.wait(calls.map((call) async {
          try {
            final input = (call['input'] as Map?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
            return {
              'type': 'tool_result',
              'tool_use_id': call['id'],
              'content': await runTool(call['name'] as String, input),
            };
          } catch (e) {
            return {
              'type': 'tool_result',
              'tool_use_id': call['id'],
              'content': e.toString(),
              'is_error': true,
            };
          }
        }));
        _messages.add({'role': 'user', 'content': results});
      }
      throw ClaudeException('Too many tool calls in one turn');
    } catch (_) {
      // Roll back this turn so the history stays valid for the next one.
      _messages.removeRange(checkpoint, _messages.length);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _send({
    required String system,
    required List<Map<String, dynamic>> tools,
  }) async {
    final body = {
      'model': model,
      'max_tokens': 16000,
      'system': system,
      'tools': tools,
      'messages': _messages,
      // Voice replies should be fast; low effort keeps thinking short.
      'output_config': {'effort': 'low'},
      // If a safety classifier declines, retry on Anthropic's recommended
      // fallback model server-side.
      if (!model.startsWith('claude-haiku')) 'fallbacks': 'default',
    };
    final http.Response res;
    try {
      res = await _http
          .post(
            _endpoint,
            headers: {
              'content-type': 'application/json',
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
              if (!model.startsWith('claude-haiku'))
                'anthropic-beta': 'server-side-fallback-2026-07-01',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 45));
    } catch (e) {
      throw ClaudeOfflineException('Could not reach Claude: $e');
    }

    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      final err = (decoded is Map ? decoded['error'] : null) as Map?;
      final msg = err?['message'] ?? 'HTTP ${res.statusCode}';
      if (res.statusCode == 401) {
        throw ClaudeException('The Anthropic API key was rejected: $msg');
      }
      if (res.statusCode == 429 || res.statusCode >= 500) {
        throw ClaudeOfflineException('Claude is busy right now: $msg');
      }
      throw ClaudeException('Claude API error: $msg');
    }
    return decoded as Map<String, dynamic>;
  }
}

class ClaudeException implements Exception {
  final String message;
  ClaudeException(this.message);
  @override
  String toString() => message;
}

/// Network or capacity problems: the assistant should fall back to offline mode.
class ClaudeOfflineException extends ClaudeException {
  ClaudeOfflineException(super.message);
}
