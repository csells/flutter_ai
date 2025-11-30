import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev show log;

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../data/recipe_repository.dart';
import '../data/settings.dart';
import '../views/recipe_list_view.dart';
import '../views/recipe_response_view.dart';
import '../views/search_box.dart';
import '../views/settings_drawer.dart';
import 'split_or_tabs.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _searchText = '';
  late LlmProvider _provider = _createProvider();

  static final _recipeLookupTool = FunctionDeclaration(
    'recipeLookup',
    'Look up recipes from the local RAG service.',
    parameters: {
      'query': Schema(
        SchemaType.string,
        description: 'The search query for recipes.',
      ),
    },
  );

  static final _returnResultTool = FunctionDeclaration(
    'returnResult',
    'Returns the generated recipes and commentary.',
    parameters: {
      'recipes': Schema(
        SchemaType.array,
        items: Schema(
          SchemaType.object,
          properties: {
            'text': Schema(SchemaType.string),
            'recipe': Schema(
              SchemaType.object,
              properties: {
                'title': Schema(SchemaType.string),
                'description': Schema(SchemaType.string),
                'ingredients': Schema(
                  SchemaType.array,
                  items: Schema(SchemaType.string),
                ),
                'instructions': Schema(
                  SchemaType.array,
                  items: Schema(SchemaType.string),
                ),
              },
            ),
          },
        ),
      ),
      'text': Schema(SchemaType.string),
    },
  );

  // create a new provider with the given history and the current settings
  LlmProvider _createProvider([List<ChatMessage>? history]) => FirebaseProvider(
    history: history,
    model: FirebaseAI.googleAI().generativeModel(
      model: 'gemini-2.5-flash',
      tools: [
        Tool.functionDeclarations([_recipeLookupTool, _returnResultTool]),
      ],
      systemInstruction: Content.system('''
You are a helpful assistant that generates recipes based on the ingredients and 
instructions provided as well as my food preferences, which are as follows:
${Settings.foodPreferences.isEmpty ? 'I don\'t have any food preferences' : Settings.foodPreferences}

### Tool: `recipeLookup`

You have access to a tool `recipeLookup` that can search for recipes in a local database. 

**When to use:**
- If the user asks for a specific type of recipe (e.g., "pasta recipes"), use this tool to find relevant recipes.

**Function signature:**
```json
${jsonEncode(_recipeLookupTool.toJson())}
```

### Tool: `returnResult`

You have a tool to return the final result of the recipe generation process.

**When to use:**
- Use this tool when you have found recipes (or confirmed none were found) and are ready to present the answer.
- You must use this tool exactly once, and only once, to return the final result.
- Do not output any natural language text directly. ALWAYS use the `returnResult` tool to communicate with the user.

**Function signature:**
```json
${jsonEncode(_returnResultTool.toJson())}
```
'''),
    ),
    onFunctionCall: _onFunctionCall,
  );

  final _welcomeMessage =
      'Hello and welcome to the Recipes sample app!\n\nIn this app, you can '
      'generate recipes based on the ingredients and instructions provided '
      'as well as your food preferences.\n\nIt also demonstrates several '
      'real-world use cases for the Flutter AI Toolkit.\n\nEnjoy!';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Example: Recipes'),
      actions: [
        IconButton(
          onPressed: _onAdd,
          tooltip: 'Add Recipe',
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    drawer: Builder(
      builder: (context) => SettingsDrawer(onSave: _onSettingsSave),
    ),
    body: SplitOrTabs(
      tabs: const [Tab(text: 'Recipes'), Tab(text: 'Chat')],
      children: [
        Column(
          children: [
            SearchBox(onSearchChanged: _updateSearchText),
            Expanded(child: RecipeListView(searchText: _searchText)),
          ],
        ),
        LlmChatView(
          provider: _provider,
          welcomeMessage: _welcomeMessage,
          responseBuilder: (context, response) => RecipeResponseView(response),
          messageSender: _messageSender,
        ),
      ],
    ),
  );

  void _updateSearchText(String text) => setState(() => _searchText = text);

  void _onAdd() => context.goNamed(
    'edit',
    pathParameters: {'recipe': RecipeRepository.newRecipeID},
  );

  void _onSettingsSave() => setState(() {
    // move the history over from the old provider to the new one
    final history = _provider.history.toList();
    _provider = _createProvider(history);
  });

  String? _capturedResult;

  Stream<String> _messageSender(
    String prompt, {
    required Iterable<Attachment> attachments,
  }) async* {
    _capturedResult = null;

    final stream = _provider.sendMessageStream(
      prompt,
      attachments: attachments,
    );

    await for (final _ in stream) {
      // consume the stream but ignore the output
    }

    if (_capturedResult != null) {
      // Update the history with the captured result to ensure it's saved correctly
      final history = _provider.history.toList();
      if (history.isNotEmpty) {
        // Create a new message with the captured result
        final newMessage = ChatMessage(
          origin: MessageOrigin.llm,
          text: _capturedResult!,
          attachments: [],
        );
        history[history.length - 1] = newMessage;
        _provider.history = history;
      }
      yield _capturedResult!;
    } else {
      // If no result was captured, yield the final text from history
      // This ensures normal chat messages are still displayed
      final history = _provider.history;
      if (history.isNotEmpty && history.last.origin.isLlm) {
        yield history.last.text ?? '';
      }
    }
  }

  Future<Map<String, Object?>?> _onFunctionCall(
    FunctionCall functionCall,
  ) async {
    if (functionCall.name == 'recipeLookup') {
      final query = functionCall.args['query'] as String;
      try {
        final response = await http.get(
          Uri.parse('http://localhost:9999/search?q=$query'),
        );
        if (response.statusCode == 200) {
          return {'result': jsonDecode(response.body)};
        } else {
          dev.log(
            'Failed to lookup recipes: ${response.statusCode} ${response.body}',
          );
          return {'error': 'Failed to lookup recipes: ${response.body}'};
        }
      } catch (e) {
        // Log the error so it's visible in the console
        dev.log('Exception during recipe lookup: $e');
        return {'error': 'Exception during recipe lookup: $e'};
      }
    } else if (functionCall.name == 'returnResult') {
      _capturedResult = jsonEncode(functionCall.args);
      // Return a dummy result to satisfy the provider, though we ignore the subsequent output
      return {'result': 'captured'};
    }
    throw Exception('Unknown function call: ${functionCall.name}');
  }
}
