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

  // create a new provider with the given history and the current settings
  LlmProvider _createProvider([List<ChatMessage>? history]) => FirebaseProvider(
    history: history,
    model: FirebaseAI.googleAI().generativeModel(
      model: 'gemini-2.5-flash',
      tools: [
        Tool.functionDeclarations([
          FunctionDeclaration(
            'recipeLookup',
            'Look up recipes from the local RAG service.',
            parameters: {
              'query': Schema(
                SchemaType.string,
                description: 'The search query for recipes.',
              ),
            },
          ),
          FunctionDeclaration(
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
          ),
        ]),
      ],
      systemInstruction: Content.system('''
You are a helpful assistant that generates recipes based on the ingredients and 
instructions provided as well as my food preferences, which are as follows:
${Settings.foodPreferences.isEmpty ? 'I don\'t have any food preferences' : Settings.foodPreferences}

You have access to a tool `recipeLookup` that can search for recipes in a local database. 
If the user asks for a specific type of recipe (e.g., "pasta recipes"), use this tool to find relevant recipes.

When you are ready to provide the recipes, you MUST use the `returnResult` tool.
Pass the recipes and commentary to this tool.
The tool will return the JSON data. You must then output this JSON data exactly as your text response.
Do not output any other text before or after the JSON.

Structure your call to `returnResult` as follows:
{
  "recipes": [
    {
      "text": "Any commentary you care to provide about the recipe.",
      "recipe":
      {
        "title": "Recipe Title",
        "description": "Recipe Description",
        "ingredients": ["Ingredient 1", "Ingredient 2", "Ingredient 3"],
        "instructions": ["Instruction 1", "Instruction 2", "Instruction 3"]
      }
    }
  ],
  "text": "any final commentary you care to provide"
}
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

  Future<Map<String, Object?>?> _onFunctionCall(
    FunctionCall functionCall,
  ) async {
    dev.log('Function call: ${functionCall.name}');
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
      dev.log('Returning result: ${functionCall.args}');
      return functionCall.args;
    }
    throw Exception('Unknown function call: ${functionCall.name}');
  }
}
