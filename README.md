# IDR command-line apps

IDR lets a user's machine (the **Source**) use services on another machine (the **Target**), such as a local Ollama or LM Studio, through Presence. Neither side opens an inbound port, and every device holds a certificate an admin approved.

| Side | CLI | README | Who runs it |
|---|---|---|---|
| **Target** | `idrt` | [idr_target_cli/README.md](idr_target_cli/README.md) | Whoever serves services, and the admin who approves devices, creates zones, sets policies and revokes |
| **Source** | `idr` | [idr_sources_cli/README.md](idr_sources_cli/README.md) | Each user who consumes those services |

```
  idr (Source) ──session request + proof──▶ Presence ──policy lookup──▶ Billing
        ▲                                     │
        └──────────── WebRTC (direct/TURN) ───┴──▶ target-agent (idrt start) ──▶ Ollama / LM Studio
```

## Modes

| Mode | Who pays | Structure | Start here |
|---|---|---|---|
| Personal | You | Your own machines; the first one is the admin | [Target](idr_target_cli/README.md#registration-personal) · [Source](idr_sources_cli/README.md#registration-personal) |
| Enterprise | An organization | Root admin → zones → members; per-zone access policies; revocation | [Target](idr_target_cli/README.md#registration-enterprise) · [Source](idr_sources_cli/README.md#registration-enterprise) |
| Service Provider | Each tenant's org (or the provider) | A provider runs Targets for customer tenants | [Target](idr_target_cli/README.md#registration-service-provider) · [Source](idr_sources_cli/README.md#registration-service-provider) |

## Order of operations

1. Start the billing server, the billing portal and Presence. See [Target: Install](idr_target_cli/README.md#install).
2. Buy the plan in the portal (`idrt billing` opens it).
3. Set up the admin machine and the Target with `idrt`. In Enterprise, also create zones and their policies.
4. Users sign in and enroll with `idr`. The admin approves them, into a zone in Enterprise.
5. Users connect with `idr connect` and `idr active <service>`.

Both CLIs share [common behavior](#common-behavior) and are [built and shipped](#build-and-distribute) the same way.

Cross-cutting topics:

- [Enterprise zones, registration, and service access](docs/enterprise-zones-registration-and-access.md) (desired vs current, tests, gaps)
- [Access policies](idr_target_cli/README.md#access-policies) (what the [user sees](idr_sources_cli/README.md#access-policies-what-the-user-sees))
- [Revocation](idr_target_cli/README.md#revocation) (what the [user sees](idr_sources_cli/README.md#revocation-what-the-user-sees))
- [Custom domains](idr_target_cli/README.md#custom-domains) (Service Provider: a tenant's own hostname with a Let's Encrypt certificate)
- [Billing](idr_target_cli/README.md#billing)
- Troubleshooting: [Target](idr_target_cli/README.md#troubleshooting) · [Source](idr_sources_cli/README.md#troubleshooting)

## Common behavior

Both CLIs are built on [`idr_cli_core`](idr_cli_core), so flags, output and exit codes match.

| Global flag | Effect |
|---|---|
| `--json` | Print exactly one JSON document on stdout: the command's data, `{"ok": true, "exitCode": 0}` for commands with nothing to report, or `{"ok": false, "error": {"code", "message", "hint", "exitCode"}}`. Progress and messages go to stderr. Implies `--no-input`. |
| `--no-color` | No ANSI colors. Colors are also off when `NO_COLOR` is set or stdout is not a terminal. |
| `--no-input` | Never prompt: a missing value is a usage error (exit `64`) that names the argument. Prompts are also off when stdin/stdout is not a terminal or `CI` is set. |
| `-v`, `--verbose` | SDK debug logs and stack traces on stderr, with secrets masked. |
| `--version` | Print the version. |

- **Home menu:** in a terminal, running `idr` or `idrt` with no command, or finishing `login` (and `idr enroll`, `idrt <mode> setup|register`), opens a menu of what fits the current state: sign in when signed out; Personal / Enterprise / Service Provider setup before a mode is chosen; register, start, services, approvals, tenants and billing afterwards (`idrt`); enroll, chat, services, connect afterwards (`idr`); plus Status, Run diagnostics, Sign out (asks first) and Exit. Use ↑/↓ and Enter; Ctrl+C leaves. Each entry runs the normal command, then the menu comes back with the state re-read; a failed entry prints its error and returns to the menu. Scripts, pipes, `--no-input`, `--json` and `CI` never see the menu: a bare invocation prints usage as before.
- **Guided next step:** `idrt`'s menu follows the SDK's own ready step. For example, an account whose billing plan is Enterprise but whose machine was never bound to the organization gets **Finish Enterprise setup** (organization picker, then role), not organization views that would fail. Nested menus show a breadcrumb (`IDR › Organization: Acme › Zones › Zone fin`) and a **Back** entry, and reload after every action.
- **Organizations, zones and devices (`idrt`, Enterprise):** *Organization* → details, *Zones* → each zone (parent, certificate, policy, zone admins, member devices from billing) with *Set allowed services*, *Approve a pending request into this zone*, *Make someone a zone admin*, *Create a sub-zone*, *Revoke this zone*; *Devices (from billing)*; *Users and roles* (CLI: list, invite, role, remove — no browser). Entries appear only for roles that can use them; the rest explain who can (e.g. "Billing lists devices only for the organization owner"). Billing still enforces every permission. Direct commands: `idrt enterprise zone list|show|add|policy|invite`, `idrt enterprise devices`, `idrt enterprise members [invite|role|remove]`, all with `--json`.
- **Which CLI does what:** `idr` is a Source device (enroll, connect, use services); zones, approvals and revocation live in `idrt` on the admin machine, and `idr`'s menu says so.
- **Organizations:** billing deliberately blocks listing memberships (its bind plugin replaces `GET /organization/list`), so pickers offer the organizations this machine has bound before (recorded from billing's bind replies, per account) plus *Another organization (enter its slug)*. Switching a set-up machine to another organization isn't supported (its certificates belong to the first one); the menu explains the sign-out-and-set-up-again path.
- **Prompts:** in a terminal, commands ask for what's missing: `idr enroll`/`connect` ask for the Target, `idr active` offers the service list, `idrt services add` asks for name and endpoint, `idrt <mode> register` for the host, `idrt enterprise|provider setup` for the org (no spaces; `me`/`personal` point you to Personal setup), `idrt <mode> approve|reject` offers the pending list, `idrt provider register` the saved tenants, `idrt provider tenant add` the tenant id. A bad answer is asked again; a bad flag value is a usage error. In scripts, pass the argument.
- **Progress:** long steps (sign-in, enroll, connect, chat, agent start) show a spinner in a terminal, and a single `…` line on stderr otherwise, so piped stdout holds only results.
- **Diagnostics:** `idr doctor [--connect]` and `idrt doctor` check configuration, billing and Presence reachability, native libraries (by loading them, not just finding the file), sign-in and identity. `idrt doctor` also checks the plan, runs `target-agent version`, validates the generated agent config with `target-agent doctor`, and reports whether the agent is running. Each failed check prints a hint, and the exit code is that of the first failure.
- **Secrets:** errors, debug logs and diagnostics are masked for JWTs, bearer tokens, token query parameters, cookies, JSON secret fields and PEM private keys. Commands never print `auth.json` or identity contents. The one deliberate exception: `idrt billing --no-open` / `idrt subscribe --no-open` print a signed-in portal link with a one-time token, because that link is what the flag is for.
- **Shell completion** (bash and zsh only): run `idr install-completion-files` or `idrt install-completion-files`, then open a new shell. Nothing is installed until you run it. PowerShell and cmd have no completion.

| Exit code | Meaning |
|---|---|
| `0` | OK |
| `1` | The operation ran but did not succeed (e.g. `idrt provider domain verify` before the CNAME exists) |
| `2` | Not signed in, or the session was rejected |
| `3` | Billing, Presence or the Target is unreachable or refused the session; or the device is still waiting for approval |
| `4` | Subscription missing or expired, or out of seats (`idrt`) |
| `5` | Configuration problem, or a native dependency is missing |
| `64` | Bad command line, or a required value is missing in a non-interactive run |
| `70` | Unexpected error (a bug): rerun with `--verbose` |

## Flavors

One executable per app serves every environment. `--flavor <name>` picks it at start and loads `config/<name>.json`. Without the flag a compiled release build (`dart build cli`, `flutter build windows --release`, every CI artifact) is `prod`, and a run from source (`dart run`, `flutter run`) is `dev`; each flavor also keeps its own local state, so a dev run never touches a prod sign-in or Target identity.

```bash
idrt --flavor dev status
```
```bash
idr --flavor=staging doctor
```
```bash
flutter run -d windows -a --flavor=dev
```

| Flavor | Backend (`config/<name>.json`) | State folders |
|---|---|---|
| `prod` | `https://billing.idr.to` (API under `/api/*`, portal at `/`), `https://public.idr.to` | `%APPDATA%\idr`, `%APPDATA%	o.idr` |
| `staging` | not set yet: pass the env vars below | `%APPDATA%\idr-staging`, `%APPDATA%	o.idr-staging` |
| `dev` | `127.0.0.1:3000`, `127.0.0.1:8081`, portal `localhost:5173` | `%APPDATA%\idr-dev`, `%APPDATA%	o.idr-dev` |

`config/` is looked up next to the executable first (CI ships only `config/prod.json` there), then upward from the working directory, so a repo checkout finds `applications/apps/config/`. Keys: `controlPlane`, `discovery`, `billingPortal`, `dev` (local stack: development mode, insecure Presence). For one run, `IDR_CONTROL_PLANE_URL` (`IDR_API_BASE_URL` for `idr`), `IDR_DISCOVERY_URL` and `IDR_BILLING_PORTAL_URL` override the file; a flavor with no URL and no env var stops with an error naming the variable.

## Build and distribute

`dart compile exe` **does not work** for these CLIs: a transitive dependency (`objective_c`, via `path_provider`) has a build hook, and `dart compile` refuses packages with build hooks. Use `dart build cli` instead. It produces the same kind of self-contained executable; the Dart SDK isn't needed to run it.

Dart doesn't cross-compile here, so build on each target OS (Windows x64, macOS, Linux). Only the Windows build has been verified so far.

On Windows, if Flutter is installed in a path with spaces, call the SDK's `dart.exe` directly (`…\flutter\bin\cache\dart-sdk\bin\dart.exe`). The `dart` launcher breaks on such paths.

1. **Build the native pieces** once, in `agents_engine/agent`:
   ```bash
   cargo build --release -p idr-c-api --features native
   cargo build --release -p idr-dp-ffi
   cargo build --release -p target-agent --features webrtc
   ```
2. **Build each CLI:**
   ```bash
   cd applications/apps/idr_sources_cli && dart pub get && dart build cli -o build/idr
   ```
   ```bash
   cd applications/apps/idr_target_cli && dart pub get && dart build cli -o build/idrt
   ```
   The executable lands in `build/<cli>/bundle/bin/`; copy `applications/apps/config/` next to it (see [Flavors](#flavors)). `dart build cli` wipes that folder on every build, so copy the native files in afterwards.
3. **Put the native files next to the executable** in `bundle/bin/`:

   | CLI | Files (Windows names; `lib….so` on Linux, `lib….dylib` on macOS) |
   |---|---|
   | `idr` | `idr_c_api.dll`, `idr_dp.dll` |
   | `idrt` | `target-agent.exe`, `idr_dp.dll` |

   On Windows, `idr_c_api.dll` and `target-agent.exe` also import **OpenSSL 3** (`libcrypto-4-x64.dll`, `libssl-4-x64.dll`) and the **Microsoft Visual C++ runtime** (`vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll`). `idr_dp.dll` needs only the VC++ runtime. Ship the OpenSSL DLLs next to the executables, and install the VC++ Redistributable (x64) where it's missing. If one is missing, `doctor` reports the library as present but not loadable.
4. **Install:** copy `bundle/` anywhere, for example `%LOCALAPPDATA%\Programs\idr` or `~/.local/share/idr`, and add its `bin` folder to `PATH`.
   - Windows (PowerShell, current user):
     ```powershell
     [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:LOCALAPPDATA\Programs\idr\bin", 'User')
     ```
   - macOS / Linux: add `export PATH="$HOME/.local/share/idr/bin:$PATH"` to `~/.bashrc` or `~/.zshrc`.

   Open a new terminal, then run `idr doctor` / `idrt doctor`.

How each native piece is found (first match wins, as implemented in the SDKs):

| Piece | Search order |
|---|---|
| `idr_c_api` (`idr`) | `IDR_C_API_LIB` → next to the executable → `agents_engine/agent/target/{release,debug}/` under the current directory or any parent, then the same from the executable's folder → the OS loader |
| `idr_dp` (both) | `IDR_DP_LIB` (the SDK silently skips it if the file is missing; `doctor` warns) → next to the executable → `agents_engine/agent/target/{release,debug}/` under the current directory or a parent (8 levels) → the OS loader (`PATH` on Windows) |
| `target-agent` (`idrt`) | `IDR_TARGET_AGENT` → next to the executable → `PATH` → `agents_engine/agent/target/{release,debug}/` under the current directory or a parent |

During development, `dart run bin/idr.dart` from inside the repo finds everything in `agents_engine/agent/target/release/` with no setup.

Configuration and state (there is no config file; endpoints come from environment variables, see each README):

| CLI | Where | What |
|---|---|---|
| `idr` | `%APPDATA%\idr\` (Windows), `~/.config/idr/`; `idr-dev`, `idr-staging` for those flavors | `secure/auth.json` (session, device private key and certificate), `prefs.json` |
| `idrt` and the Target GUI (shared) | `%APPDATA%\to.idr\idr_target\` (`$HOME/to.idr/idr_target/` elsewhere); `to.idr-dev`, `to.idr-staging` for those flavors | `secure/auth.json` (session, bound org, identity, CA private keys on admin machines), agent config, certificate, agent database |
| `idrt` | `%APPDATA%\to.idr\idrt\`, `~/.config/to.idr/idrt/` | `orgs.json` (org picker history) |

`auth.json` is encrypted with Windows DPAPI (readable only by your Windows account); on Linux / macOS it is plain JSON with mode 0600.

## Known limitations

- **No transport or tunnel details.** `idr connect` shows the Target and that the transport is a WebRTC data channel through Presence. `idr_c_api` doesn't report whether the path is direct or through TURN, and `idr` opens streams in-process, so there's no local port or tunnel to show.
- **One connection per command.** Each `idr` command runs in its own process and closes its connection on exit. `idr disconnect` matters only within one process; the chat REPL keeps its connection while open.
- **The agent runs in the foreground.** `idrt start` supervises `target-agent` until Ctrl+C. There is no background mode or `stop` command: use the OS service manager to keep it running. `idrt status` and `doctor` report the agent as running when its metrics port (`127.0.0.1:9091`) answers.
- **Zone members need the organization owner.** Billing's `credential-list` (owner only) now returns each device's `zone`, so `idrt enterprise devices` has a zone column and a zone's view lists its member Targets and Sources. For anyone else, billing refuses the list and the CLI says so instead of guessing.
- **Zone names, zone admins and devices recorded here are local** to the admin machine's org graph; billing records zone certificates and policies (zones issued from another admin machine appear as "issued elsewhere").
- **Completion** works in bash and zsh only.
- **One running Target agent per Windows user across flavors.** State is separate per flavor, but `target-agent`'s local IPC pipe name (`idr-target-agent-<user SID>`) isn't: while a dev agent runs, starting the prod one reports `AGENT_ALREADY_RUNNING`.
