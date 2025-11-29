// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:google_cloud_ai_generativelanguage_v1beta/generativelanguage.dart'
    as gl;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

// Model to use for embeddings
const _modelName = 'models/text-embedding-004';

void main(List<String> args) async {
  // 1. Check for API Key
  final apiKey = io.Platform.environment['GEMINI_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    io.stderr.writeln('Error: GEMINI_API_KEY environment variable is not set.');
    io.exit(1);
  }

  // 2. Setup Router
  final router = Router();

  router.get('/reset', (Request request) => _handleReset(request, apiKey));
  router.get('/search', (Request request) => _handleSearch(request, apiKey));

  // 3. Start Server
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router.call);
  final server = await shelf_io.serve(handler, 'localhost', 9999);

  print('Serving at http://${server.address.host}:${server.port}');
}

Future<Response> _handleReset(Request request, String apiKey) async {
  final recipesFile = io.File('recipes.json');
  if (!await recipesFile.exists()) {
    return Response.internalServerError(body: 'recipes.json not found');
  }

  final recipesJson = jsonDecode(await recipesFile.readAsString()) as List;
  final recipes = recipesJson.cast<Map<String, dynamic>>();
  final embeddingsFile = io.File('embeddings.json');

  if (await embeddingsFile.exists()) {
    await embeddingsFile.delete();
  }

  // Create a stream controller to stream the response
  final controller = StreamController<List<int>>();

  // Process in background
  _generateEmbeddings(recipes, apiKey, controller, embeddingsFile);

  return Response.ok(
    controller.stream,
    context: {
      'shelf.io.buffer_output': false,
    }, // Disable buffering for streaming
    headers: {'Content-Type': 'text/plain'},
  );
}

Future<void> _generateEmbeddings(
  List<Map<String, dynamic>> recipes,
  String apiKey,
  StreamController<List<int>> controller,
  io.File embeddingsFile,
) async {
  final embeddings = <Map<String, dynamic>>[];
  final api = gl.GenerativeService.fromApiKey(apiKey);

  try {
    for (final recipe in recipes) {
      final title = recipe['title'] as String;
      final description = recipe['description'] as String;
      final ingredients = (recipe['ingredients'] as List).join(', ');
      final instructions = (recipe['instructions'] as List).join(' ');

      final textToEmbed =
          'Title: $title\n'
          'Description: $description\n'
          'Ingredients: $ingredients\n'
          'Instructions: $instructions';

      final request = gl.EmbedContentRequest(
        model: _modelName,
        content: gl.Content(parts: [gl.Part(text: textToEmbed)]),
      );

      try {
        final response = await api.embedContent(request);
        final embeddingValues = response.embedding?.values;

        if (embeddingValues != null) {
          embeddings.add({'id': recipe['id'], 'embedding': embeddingValues});
          controller.add(utf8.encode('Generated embedding for: $title\n'));
        } else {
          controller.add(
            utf8.encode(
              'Failed to generate embedding for: $title (No values)\n',
            ),
          );
        }
      } catch (e) {
        controller.add(
          utf8.encode('Error generating embedding for $title: $e\n'),
        );
      }
    }

    await embeddingsFile.writeAsString(jsonEncode(embeddings));
    controller.add(utf8.encode('Done. Saved to embeddings.json\n'));
  } catch (e) {
    controller.add(utf8.encode('Fatal error: $e\n'));
  } finally {
    controller.close();
  }
}

Future<Response> _handleSearch(Request request, String apiKey) async {
  final query = request.url.queryParameters['q'];
  if (query == null || query.isEmpty) {
    return Response.badRequest(body: 'Missing query parameter "q"');
  }

  final embeddingsFile = io.File('embeddings.json');
  if (!await embeddingsFile.exists()) {
    return Response.internalServerError(
      body: 'embeddings.json not found. Run /reset first.',
    );
  }

  final recipesFile = io.File('recipes.json');
  if (!await recipesFile.exists()) {
    return Response.internalServerError(body: 'recipes.json not found');
  }

  final embeddingsJson =
      jsonDecode(await embeddingsFile.readAsString()) as List;
  final storedEmbeddings = embeddingsJson.cast<Map<String, dynamic>>();

  final recipesJson = jsonDecode(await recipesFile.readAsString()) as List;
  final recipes = recipesJson.cast<Map<String, dynamic>>();
  final recipeMap = {for (var r in recipes) r['id']: r};

  final api = gl.GenerativeService.fromApiKey(apiKey);

  try {
    final request = gl.EmbedContentRequest(
      model: _modelName,
      content: gl.Content(parts: [gl.Part(text: query)]),
    );

    final response = await api.embedContent(request);
    final queryEmbedding = response.embedding?.values;

    if (queryEmbedding == null) {
      return Response.internalServerError(
        body: 'Failed to generate embedding for query',
      );
    }

    final results = <Map<String, dynamic>>[];

    for (final item in storedEmbeddings) {
      final id = item['id'] as String;
      final embedding = (item['embedding'] as List).cast<double>();
      final distance = _cosineDistance(queryEmbedding, embedding);
      results.add({'id': id, 'distance': distance});
    }

    results.sort(
      (a, b) => (a['distance'] as double).compareTo(b['distance'] as double),
    );

    final top3 =
        results.take(3).map((result) {
          final recipe = recipeMap[result['id']];
          return {...recipe!, 'distance': result['distance']};
        }).toList();

    return Response.ok(
      jsonEncode(top3),
      headers: {'Content-Type': 'application/json'},
    );
  } catch (e) {
    return Response.internalServerError(body: 'Error during search: $e');
  } finally {
    api.close();
  }
}

// Cosine Distance = 1 - Cosine Similarity
double _cosineDistance(List<double> vecA, List<double> vecB) {
  var dotProduct = 0.0;
  var normA = 0.0;
  var normB = 0.0;

  for (var i = 0; i < vecA.length; i++) {
    dotProduct += vecA[i] * vecB[i];
    normA += vecA[i] * vecA[i];
    normB += vecB[i] * vecB[i];
  }

  if (normA == 0 || normB == 0) return 1.0; // Max distance if zero vector

  final similarity = dotProduct / (sqrt(normA) * sqrt(normB));
  return 1.0 - similarity;
}
