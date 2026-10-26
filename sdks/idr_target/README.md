# idr_target — Target Agent Dart SDK

Production facade for IDR Target: SSO, entity/host registration, DP enrollment, entitlement JWT, phased TLS, and `target-agent` lifecycle.

## Quick start

```dart
import 'package:idr_target/idr_target.dart';

final target = IdrTarget(
  config: IdrTargetConfig(
    controlPlaneUrl: Uri.parse('http://127.0.0.1:3000'), // billing Auth+Billing
    agentBinaryPath: r'C:\dev\idrto\agents_engine\agent\target\release\target-agent.exe',
    mode: IdrTargetMode.development,
  ),
);

await target.start();
if (target.status == IdrTargetStatus.signedOut) {
  await target.signIn();
}
if (target.state.readyStep is BillingRequired) {
  await target.startCheckout('idr_personal_bundle');
  await target.hydrateSubscription();
}
if (target.attention?.code == IdrTargetAttentionCode.hostRegistrationRequired) {
  await target.registerHost(label: 'laptop');
}
```

**Control plane:** set `controlPlaneUrl` (or env `IDR_CONTROL_PLANE_URL`) to the **billing** server. SSO, hosts, CSR enroll, and `agent/token` all use that origin. `@idrto/api` is not required for Target V1.

## Native `idr_dp` library

Enrollment, CSRs, SKIs, and proof-of-possession need the native `idr_dp` library next to the process (Windows `idr_dp.dll`, macOS `libidr_dp.dylib`, Linux `libidr_dp.so`). Consumers import `package:idr_target` only — do not load the library yourself.

**Default:** omit `crypto`. `IdrTarget` opens `idr_dp` on the first crypto call (`registerHost`, enroll, entitlement, TLS CSR).

**Where it looks (first match wins):**

1. `IdrDpCrypto.open(libraryPath: …)` if you passed a `crypto:` instance
2. env `IDR_DP_LIB` (absolute path to the library file)
3. same directory as the running executable
4. walk up from the working directory: `agents_engine/agent/target/{release,debug}/`
5. the OS library search path

**Ship it:** copy the built file next to your app binary (Flutter: `dart run tool/copy_idr_dp_native.dart` in `target_app`). For local runs, leave it in `agents_engine/agent/target/release/` or set `IDR_DP_LIB`.

```bash
cd agents_engine/agent
cargo build -p idr-dp-ffi --release
```

**Pin a path:**

```dart
IdrTarget(
  config: config,
  crypto: IdrDpCrypto.open(libraryPath: r'C:\path\to\idr_dp.dll'),
);
```

**Tests / no native lib:** pass any `IdrCrypto` implementation. If the library is missing and you did not inject `crypto`, you get `CRYPTO_UNAVAILABLE`.

**Platform (injectable on `IdrTarget`):**

```dart
IdrTarget(
  config: config,
  secureStorage: MySecureStorage(),           // IdrSecureStorage
  urlLauncher: ProcessIdrUrlLauncher(),      // or custom IdrUrlLauncher
);
```

- `IdrSecureStorage` — default `FlutterIdrSecureStorage` (flutter_secure_storage)
- `IdrUrlLauncher` — default `UrlLauncherIdrUrlLauncher`; use `ProcessIdrUrlLauncher` for `Process.run` (`start` / `open` / `xdg-open`), or inject your own to customize auth browser handoff

**State:** observe `target.state` / `stateStream` (`TargetState` + sealed `TargetReadyStep`). Ready ≠ agent running.

Verified FQHN shape: `{host}--{entity}.idr.to` (e.g. `laptop--user@gmail.com.idr.to`). Agents DEF-encode only for Presence placement.

## Sign-in / enroll

| Method | Path |
|--------|------|
| Login options | `GET /v1/auth/login-options` |
| Desktop Google | `/v1/auth/desktop/start` → complete → loopback (`token` JWT + `session_token`) |
| Refresh access JWT | `GET /api/auth/token` (session cookie / bearer) |
| Ensure email entity | `POST /api/v1/registration/entities/email` |
| Register host | `POST /api/v1/hosts` → `verifiedFqhn` |
| CSR enroll | `/api/auth/delegate-permissions/enroll-*` |
| Entitlement | `POST /api/auth/agent/token` |

Admin CSR: `listPendingEnrollments` / `approveEnrollment` / `rejectEnrollment`. Device: `refreshEnrollmentPull`.

## Rules

- **FQHN:** never typed by the user. Register a host **label**; control plane returns `host--entity.idr.to`.
- **Secrets:** private keys / JWTs only in secure storage — never TOML/logs/CLI.
- Ship `idr_dp` with the desktop app (or set `IDR_DP_LIB`). Inject `IdrCrypto` only in tests.
