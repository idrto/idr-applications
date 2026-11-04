# idr_source

Production Source SDK: billing SSO (`two_key_dart_sdk`, headless entry), Source device enroll / mTLS identity (`idr_dp_ffi` over the `idr_dp_*` ABI exported by `idr_c_api`), Presence/WebRTC connect (`idr_client`), and Target chat services (Ollama / Hugging Face).

## Install

Path dependency from the monorepo:

```yaml
dependencies:
  idr_source:
    path: ../sdks/idr_source
```

## Quick use

```dart
final source = IdrSource(
  config: IdrSourceConfig.forFlavor(IdrFlavor.current),
  // CLI default is FileAuthStorage(); Flutter apps pass
  // SecureBillingAuthStorage(storagePrefix: IdrSource.storagePrefix).
  prefs: FileSourcePrefs(),
);

await source.start();
await source.login();                          // Google SSO via loopback browser redirect
await source.enroll(fqhn: 'laptop--you@gmail.com'); // machine_source CSR; Admin approves → mTLS
await source.connect('laptop--you@gmail.com'); // mTLS when enrolled, bearer otherwise
await source.activate('ollama');
final reply = await source.chat('hello', history: const []);
```

## Config

`IdrSourceConfig.forFlavor(flavor)` takes billing + discovery URLs from the run's flavor (`IdrFlavor` in `idr_session`; the app's `main` calls `IdrFlavor.init(args)`, which reads `--flavor` and `config/<name>.json`):

| Flavor | API | Discovery |
|------|-----|-----------|
| `dev` | `http://127.0.0.1:3000` | `http://127.0.0.1:8081/.well-known/idr-presence.json` |
| `staging` | not set yet (env vars required) | not set yet |
| `prod` | `https://billing.idr.to` | `https://public.idr.to/.well-known/idr-presence.json` |

Optional env overrides: `IDR_API_BASE_URL`, `IDR_DISCOVERY_URL`, `IDR_C_API_LIB`.

Native library: `config.libraryPath`, else env, else walk-up to `agents_engine/agent/target/{release,debug}/idr_c_api.{dll,so,dylib}`. Build with `cargo build -p idr-c-api --release --features native` (also exports the `idr_dp_*` crypto ABI, so no separate `idr_dp` lib is needed).

## Lifecycle

- Persist **last FQHN** / active service / model names via `SourcePrefs`.
- **Never** persist a live WebRTC peer — call `ensureConnected()` each process that needs Target.
- Observe `state` / `stateStream` (`SignedOut` → `SignedIn` → `Connected` → `ServiceActive`).

## CLI

See [`idr_sources_cli`](../../idr_sources_cli) for the `idr` command-line tool built on this SDK.
