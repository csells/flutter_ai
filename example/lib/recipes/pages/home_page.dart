import 'package:flutter/material.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:go_router/go_router.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

import '../../gemini_api_key.dart';
import '../data/recipe_data.dart';
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
  LlmProvider _createProvider([List<ChatMessage>? history]) => GeminiProvider(
        history: history,
        model: GenerativeModel(
          model: 'gemini-2.0-flash',
          apiKey: geminiApiKey,
          generationConfig: GenerationConfig(
            responseMimeType: 'application/json',
            responseSchema: Schema(
              SchemaType.object,
              properties: {
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
                        requiredProperties: [
                          'title',
                          'description',
                          'ingredients',
                          'instructions',
                        ],
                      ),
                    },
                    requiredProperties: [
                      'recipe',
                    ],
                  ),
                ),
                'text': Schema(SchemaType.string),
              },
              requiredProperties: [
                'recipes',
              ],
            ),
          ),
          systemInstruction: Content.system(
            '''
You are a helpful assistant that generates recipes based on the ingredients and 
instructions provided as well as my food preferences, which are as follows:
${Settings.foodPreferences.isEmpty ? 'I don\'t have any food preferences' : Settings.foodPreferences}

You should keep things casual and friendly. You may generate multiple recipes in
a single response, but only if asked. Generate each response in JSON format
with the following schema, including one or more "text" and "recipe" pairs as
well as any trailing text commentary you care to provide:

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
  "text": "any final commentary you care to provide",
}
''',
          ),
        ),
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
          tabs: const [
            Tab(text: 'Recipes'),
            Tab(text: 'Chat'),
          ],
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
              responseBuilder: (context, response) => RecipeResponseView(
                response,
              ),
              messageSender: _sendMessage,
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

  // send a message to the LLM, augmenting the prompt with a referenced recipe,
  // if there is one. if a search finds a recipe, we include it with the user's
  // original prompt and send the augmented prompt to the LLM. however, we do
  // this using a separate provider so that the augmented prompt doesn't show up
  // in the user's chat history.
  Stream<String> _sendMessage(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) async* {
    // look for an existing recipe that matches the prompt
    final recipe = await _searchEmbeddings(prompt);
    if (recipe == null) {
      // if there's no matching recipe, don't do anything special for RAG;
      // just send the prompt and attachments to the main LLM
      yield* _provider.sendMessageStream(prompt, attachments: attachments);
      return;
    }

    // augment the user's prompt with the referenced recipe
    final ragPrompt = StringBuffer();
    ragPrompt.writeln("# Referenced Recipe:");
    ragPrompt.write(recipe.toString());
    ragPrompt.writeln();
    ragPrompt.write(prompt);

    // create a provider for this prompt using the same history as the current
    // provider; this way the user's original prompt is maintained, even though
    // we're sending an augmented prompt to the LLM
    final ragProvider = _createProvider(_provider.history.toList());

    // send the augmented prompt to the LLM
    yield* ragProvider.sendMessageStream(
      ragPrompt.toString(),
      attachments: attachments,
    );

    // now augment the original history with the user's original prompt and the
    // LLM's response to the RAG prompt
    _provider.history = [
      ..._provider.history,
      ChatMessage.user(prompt, attachments),
      ragProvider.history.last,
    ];
  }

  Future<Recipe?> _searchEmbeddings(String prompt) async {
    final embeddingHelper = GeminiEmbeddingHelper(embeddingModel);
    final queryEmbedding = await embeddingHelper.getQueryEmbedding(prompt);
    Recipe? topRecipe;
    var topScore = 0.0;
    for (final recipe in _grandmasRecipes!) {
      final embedding = _grandmasEmbeddings!.singleWhere(
        (e) => e.id == recipe.id,
      );

      final score = GeminiEmbeddingHelper.computeDotProduct(
        queryEmbedding,
        embedding.embedding,
      );

      if (score > topScore) {
        topScore = score;
        topRecipe = recipe;
      }
    }

    return topRecipe;
  }
}
