# Recipe RAG Service

A simple Retrieval-Augmented Generation (RAG) service for recipes, built with
Dart and the Gemini API.

## Features

-   **Embeddings Generation**: Converts recipes into vector embeddings using
    Google's Gemini models.
-   **Semantic Search**: Allows searching for recipes using natural language
    queries via cosine similarity.
-   **Streaming Responses**: Real-time feedback during embedding generation.

## Setup

1.  **Get an API Key**:
    -   Obtain an API key from [Google AI Studio](https://aistudio.google.com/).
    -   Set the `GEMINI_API_KEY` environment variable:
        ```bash
        export GEMINI_API_KEY=your_api_key_here
        ```

2.  **Install Dependencies**:
    ```bash
    dart pub get
    ```

## Running the Service

Start the server on `localhost:9999`:

```bash
dart run bin/server.dart
```

## Usage

### 1. Generate Embeddings (`/reset`)

Initialize the service by generating embeddings for the recipes in
`recipes.json`. This must be done before searching.

```bash
curl http://localhost:9999/reset
```

**Response:** The server will stream the titles of recipes as they are
processed.
```text
Generated embedding for: Spaghetti and Meatballs
Generated embedding for: Chicken Stir-Fry
...
Done. Saved to embeddings.json
```

### 2. Search Recipes (`/search`)

Search for recipes using a query string.

```bash
curl "http://localhost:9999/search?q=pasta"
```

**Response:** Returns a JSON list of the top 3 matching recipes with their
similarity distance.

```json
[
  {
    "id": "...",
    "title": "Spaghetti and Meatballs",
    "description": "A classic Italian comfort food dish.",
    ...
    "distance": 0.4046...
  },
  ...
]
```
