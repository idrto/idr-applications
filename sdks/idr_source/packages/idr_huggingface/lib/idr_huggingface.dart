/// Chat / image helpers for Hugging Face via IDR mux (`openStream('huggingface')`).
///
/// The Target must expose a `[[services]]` entry that injects `Authorization`
/// from `HF_TOKEN`. This package is **Source-side only**.
library idr_huggingface;

export 'src/client.dart';
export 'src/models.dart';
