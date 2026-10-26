/// Chat with a Target-local Ollama instance via IDR mux (`openStream('ollama')`).
///
/// The Target must expose a `[[services]]` entry named `ollama` (generic HTTP
/// gateway). This package is **Source-side only** — it speaks the Ollama HTTP
/// API over the multiplexed byte stream.
library idr_ollama;

export 'src/client.dart';
export 'src/models.dart';
