# idr: the Source CLI

`idr` is the **user's side**: it signs a person in, enrolls their machine as a **Source device**, connects to a Target through Presence (WebRTC, no inbound ports on either side), and lets them use the Target's services, for example by chatting with a model on Ollama or LM Studio.

Targets and all admin work (approving devices, zones, policies, revocation) use the [`idrt` CLI](../idr_target_cli/README.md). For how the two fit together, see the [overview](../README.md).

Built on [`package:idr_source`](../sdks/idr_source).

- [Role in the system](#role-in-the-system)
- [Install](#install)
- [Configuration](#configuration)
- [Commands](#commands)
- [Registration: Personal](#registration-personal)
- [Registration: Enterprise](#registration-enterprise)
- [Registration: Service Provider](#registration-service-provider)
- [File transfer](#file-transfer)
- [Access policies: what the user sees](#access-policies-what-the-user-sees)
- [Revocation: what the user sees](#revocation-what-the-user-sees)
- [Billing](#billing)
- [Troubleshooting](#troubleshooting)

## Role in the system

1. **Sign-in** (`idr login`) goes to billing only.
2. **Enroll** (`idr enroll`) creates a key pair on this machine and sends a certificate request. An admin approves it with `idrt … approve`, which signs the certificate (in Enterprise, under the user's zone). The private key never leaves the machine.
3. **Connect** (`idr connect`, `idr active`) asks Presence for a session to the Target and proves who you are with that certificate.
   - Presence checks the certificate chain and asks billing whether you are still allowed and which services your zone may use.
   - The Target then serves only those services.

A Source holds no admin powers and needs no subscription of its own. The organization (or, in Personal, the same user) pays, and each approved Source takes one seat.

## Install

From the repo root:

```bash
cd applications/apps/idr_sources_cli
dart pub get
dart run bin/idr.dart --help
```

Optional, to get a global `idr` command:

```bash
dart pub global activate --source path .
```

Examples below write `idr` for `dart run bin/idr.dart`.

Native libraries, built once from `agents_engine/agent`:

```bash
cargo build --release -p idr-c-api --features native
cargo build --release -p idr-dp-ffi
```

- `idr_c_api` handles the WebRTC connection.
- `idr_dp` handles certificate crypto for enrollment and the session proof.
- Both land in `agents_engine/agent/target/release/`. The CLI walks up from the current directory to find them, or you can set the paths explicitly (see below).

Run `idr doctor` to check that everything is found. To build a standalone `idr` executable for other users, see [Build and distribute](../README.md#build-and-distribute).

The Source needs the billing server and Presence running, and a Target online. See the [Target README](../idr_target_cli/README.md#install).

## Configuration

There is no config file to write: `--flavor dev|staging|prod` (default: prod for a release build, dev under `dart run`; see Flavors in `../README.md`) sets the endpoints and the state folder (`idr.to-s`, `idr.to-s-dev`, …). Overrides:

| Variable | Default (dev flavor) | Purpose |
|---|---|---|
| `IDR_API_BASE_URL` | `http://127.0.0.1:3000` | Billing / auth API |
| `IDR_DISCOVERY_URL` | `http://127.0.0.1:8081/.well-known/idr-presence.json` | Presence discovery |
| `IDR_C_API_LIB` | next to `idr`, then searched upward | Full path to `idr_c_api` |
| `IDR_DP_LIB` | next to `idr`, then searched upward | Full path to `idr_dp` |
| `NO_COLOR` | unset | Any value turns colors off |
| `APPDATA` (Windows) / `HOME` | OS default | Root of local state. Set it to keep a second user's profile on one machine. |

Files:

| Path | Contents |
|---|---|
| `%APPDATA%/idr.to-s/secure/auth.json` (or `~/.config/idr.to-s/secure/auth.json`) | Sign-in session and the device identity: **private key** and certificate chain. Encrypted with DPAPI on Windows; plain JSON (mode 0600) elsewhere: protect it like a key. |
| `%APPDATA%/idr.to-s/prefs.json` | Last Target FQHN, active service, active model |

## Commands

| Command | Does |
|---|---|
| `idr login [--force]` | Sign in through the browser (Google SSO via billing) |
| `idr logout [--forget-device]` | Sign out and clear connection prefs. The enrolled device stays, so `idr login` resumes without re-enrolling. `--forget-device` also deletes this machine's key and certificate. |
| `idr status` | Mode, URLs, account, last Target, active service/model, readiness, anything needing attention |
| `idr enroll [<target-fqhn>] [--org <slug>] [--label <name>]` | Enroll this machine as a Source and wait briefly for approval |
| `idr connect [<target-fqhn>]` | Connect and list the services you may use. Saves the Target for later commands. |
| `idr disconnect` | Drop the live connection |
| `idr services` | The Target's service catalog, filtered to what you may use |
| `idr models` | Models of the active service (`*` marks the active one) |
| `idr active [<service>] [--model m] [--prompt "…"]` | Activate a service (asks which one if omitted). Chat services open a REPL; `--prompt` sends one message and exits. |
| `idr doctor [--connect [<target-fqhn>]]` | Check config, billing and Presence reachability, native libraries, sign-in and enrollment; `--connect` also opens a session to the Target |
| `idr transfer send\|list\|status\|accept\|reject\|pause\|resume\|cancel\|retry-failed` | Send and receive files and folders. Needs `source-agent run`; see [File transfer](#file-transfer). |
| `idr version` | CLI, SDK and Dart versions |

Global flags (`--json`, `--no-color`, `--no-input`, `--verbose`), prompts and exit codes are shared with `idrt`: see [Common behavior](../README.md#common-behavior). `idr connect` prints the Target, the transport and the local port (always none: streams are in-process).

Target FQHNs look like `gpu-box--you@acme.com.idr.to`. The `.idr.to` suffix is optional.

REPL inputs (`idr active ollama`):

| Input | Action |
|---|---|
| any text | Send it to the model, keeping the conversation history |
| `/model [id]` | Show or switch the model |
| `/models` | List models |
| `/status` | Target, service, model |
| `/quit`, `/exit`, `/q` | Leave |

The REPL needs a real terminal. In scripts, use `--prompt`.

## Registration: Personal

You and your own machines. Your Personal subscription pays.

1. **On the Target side**, the admin machine is set up and a Target is serving. See [Target: Personal](../idr_target_cli/README.md#registration-personal).
2. **Sign in** with the same account:
   ```bash
   idr login
   ```
   Result: `Signed in as you@example.com.`
3. **Enroll** against your Target:
   ```bash
   idr enroll laptop--you@example.com
   ```
   Result: `Source device … is waiting for Target Admin approval. Run enroll again after approval.` (exit `3`, or `{"status": "pending", …}` with `--json`).
4. **Approve** on the admin machine:
   ```bash
   idrt personal pending
   idrt personal approve <id>
   ```
5. **Finish enrolling**, then connect:
   ```bash
   idr enroll
   idr connect laptop--you@example.com
   ```
   - `idr enroll` prints `Source device approved: <label>--you@example.com`.
   - `idr connect` prints `Connected to laptop--you@example.com.idr.to.` and the service list.
6. **Use it:**
   ```bash
   idr active ollama --model gemma3:1b --prompt "Reply with the single word: pong"
   ```
   Result: `Active: ollama · gemma3:1b`, then the reply.

## Registration: Enterprise

You are a member of an organization. An admin puts your device in a **zone**, and the zone's policy decides what you can reach.

1. **Get invited.** An org owner adds your account under **Members** in the billing portal. The `member` role is enough for a Source.
2. **Sign in:**
   ```bash
   idr login
   ```
3. **Enroll into the org.** Get the Target FQHN and the org slug from your admin:
   ```bash
   idr enroll gpu-box--admin@acme.com --org acme --label alice-laptop
   ```
   - `--org` binds your sign-in to the organization first. Without it, the request goes to your personal account and the admin never sees it.
   - Result: `Bound to acme (acme) as member.`, then `… is waiting for Target Admin approval.` (exit `3`).
4. **The admin approves you into your zone** on the root admin machine:
   ```bash
   idrt enterprise approve <id> --zone zone-a
   ```
5. **Finish enrolling and connect:**
   ```bash
   idr enroll
   idr connect gpu-box--admin@acme.com
   ```
   - `idr enroll` prints `Source device approved: alice-laptop--admin@acme.com`.
   - `idr connect` lists only your zone's services, for example `ollama  (ollama)`.
6. **Use it:**
   ```bash
   idr active ollama
   ```

A Source never picks its own zone: the admin's `--zone` on approval decides it.

## Registration: Service Provider

A provider runs the Target for your organization, which is the provider's tenant.

1. Your organization's owner invites you under **Members** in the portal.
2. Sign in and enroll into that org:
   ```bash
   idr login
   idr enroll cam01--provider@sp.com --org acme
   ```
3. Any provider machine approves you: `idrt provider approve <id>`.
4. Finish enrolling and connect:
   ```bash
   idr enroll
   idr connect cam01--provider@sp.com
   ```

Service Provider mode has no zones: every approved Source sees every service on the tenant's Target.

## File transfer

Send files and folders to a Target, and receive them from it. Transfers run in the **Source agent** (`source-agent run`), a background process that keeps a session with each Target you list. It:

- sends and receives over the same peer-to-peer connection as your services (no inbound ports);
- survives drops: an interrupted transfer resumes where it stopped, even after a restart of either side;
- verifies every file by SHA-256 before it is moved into place.

`idr transfer …` only talks to that agent. If the agent isn't running, you get `source-agent is not running`.

### Before you start

- This machine is enrolled and approved (see [Registration](#registration-personal)), and `idr connect <target>` works.
- The Target runs a Target agent with file transfer on (the default for `idrt start` and the Target GUI).
- Presence runs with `PRESENCE_SERVICE_TOKEN` set. Without it, the Target can't verify this Source and refuses transfers (`Target refused peer binding` in the agent log).

### 1. Build the Source agent

From `agents_engine/agent`:

```bash
cargo build --release -p source-agent
```

You get `target/release/source-agent.exe` (or `source-agent`).

### 2. Save this device's identity for the agent

The agent proves who you are with the same key and certificate `idr enroll` created. `idr` keeps them in `%APPDATA%/idr.to-s/secure/auth.json` under `idr.source.identity`; copy that entry into a file of its own.

PowerShell:

```powershell
# auth.json is DPAPI-encrypted: decrypt it as your Windows user.
Add-Type -AssemblyName System.Security
$raw = [IO.File]::ReadAllBytes("$env:APPDATA\idr\secure\auth.json")
$json = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($raw, $null, 'CurrentUser'))
$id = ($json | ConvertFrom-Json).'idr.source.identity'
[IO.File]::WriteAllText("$env:APPDATA\idr\source-identity.json", $id)   # no BOM
```

Linux / macOS (needs `jq`):

```bash
jq -r '."idr.source.identity"' ~/.config/idr.to-s/secure/auth.json > ~/.config/idr.to-s/source-identity.json
chmod 600 ~/.config/idr.to-s/source-identity.json
```

The file contains your **private key**. Keep it on this machine, never share or commit it, and redo this step after `idr enroll` issues a new certificate.

### 3. Write the agent config

Save it as, for example, `%APPDATA%/idr.to-s/source.toml`:

```toml
[source]
source_id = "my-laptop"            # any label; shows in logs

[presence]
discovery_url = "http://127.0.0.1:8081/.well-known/idr-presence.json"
discovery_key = ""                 # empty = dev (unsigned discovery accepted)

[dp]
identity_path = "C:/Users/you/AppData/Roaming/idr/source-identity.json"

[daemon]
data_dir = "C:/Users/you/AppData/Roaming/idr/source-agent"   # transfer queue and state
targets = ["laptop--you@example.com.idr.to"]                  # Targets to stay connected to

[file_transfer]
enabled = true
receive_dir = "C:/Users/you/Downloads/IDR"   # where accepted files land
interactive = true                           # ask before accepting (see "Receiving")
# permitted_dirs = ["D:/Shared"]             # other folders `accept --out` may use
```

| Setting | Meaning |
|---|---|
| `[daemon].targets` | Every Target this machine keeps a session with. You can only send to, and receive from, these. List several to use several Targets. |
| `[file_transfer].enabled` | Off unless `true` |
| `receive_dir` | Default folder for accepted transfers. Created if missing. |
| `interactive` | `true`: incoming offers wait for `idr transfer accept`/`reject`. `false` (headless): offers are refused unless a peer rule allows them. |
| `permitted_dirs` | Extra folders `accept --out` may write to. `receive_dir` and its subfolders are always allowed. |
| `[[file_transfer.peers]]` `ski`, `auto_accept`, `auto_accept_max_bytes` | Accept offers from that Target automatically, up to a size |
| `lease_minutes` | How long one authorization lasts (default 15, at least 5). The agent then re-authorizes through Presence; transfers pause for a moment and continue. |

### 4. Run the agent

Keep it running in its own terminal:

```powershell
source-agent --config "$env:APPDATA\idr\source.toml" run
```

(Linux / macOS: `source-agent --config ~/.config/idr.to-s/source.toml run`.)

`session up fqhn=…` in its output means it is connected to that Target. Leave it running; it reconnects by itself when the network or the Target comes back.

Point `idr` at the same agent and config in the shell where you run `idr transfer` (add these to your profile to keep them):

```powershell
$env:IDR_SOURCE_AGENT  = "C:\dev\idrto\agents_engine\agent\target\release\source-agent.exe"
$env:IDR_SOURCE_CONFIG = "$env:APPDATA\idr\source.toml"
```

`IDR_SOURCE_AGENT` can be left unset when `source-agent` is on your `PATH`.

From the interactive menu (`idr` with no arguments), once a Target is set:

- **Send a file or folder to this Target** asks for one path and sends it (a folder is sent as a folder).
- **File transfers** lists what's waiting for you, with **Accept**, **Accept … into a folder…** and **Reject** for each pending offer, plus **Show all transfers**. If the Source agent isn't running, it says so and how to start it.

The commands below do the same, plus several files at once.

### Sending to a Target

```bash
idr transfer send --target laptop--you@example.com --file report.pdf --file photo.jpg
idr transfer send --target laptop--you@example.com --dir ./project
```

- Result: `Queued <id>.` The agent sends it in the background.
- `--file` can be repeated; `--dir` sends a whole folder, including subfolders, empty folders and empty files.
- The Target's owner then accepts it (`idrt transfer accept`, or **Accept** in the Target GUI). Until then the transfer shows as `running` (waiting for the Target).
- Follow it with `idr transfer status <id>` or `idr transfer list`. It ends as `completed`.

### Receiving from a Target

When the Target sends you something, it appears as a pending offer:

```bash
idr transfer list                         # state "pending", with the file names and size
idr transfer accept <id>                  # into receive_dir
idr transfer accept <id> --out D:/Shared  # into a permitted folder
idr transfer reject <id>
```

- `--out` must be an existing folder inside `receive_dir` or one of `permitted_dirs`; anything else is refused.
- Offers you don't answer expire after a while and are refused.
- Files are written to a hidden staging folder first and only appear under their real names once complete and verified.

### Managing transfers

| Command | Does |
|---|---|
| `idr transfer list` | All transfers and pending offers |
| `idr transfer status <id>` | State, contents, connection path and progress |
| `idr transfer pause <id>` / `resume <id>` | Pause or continue |
| `idr transfer cancel <id>` | Stop and remove the partial data |
| `idr transfer retry-failed <id>` | Re-send only the files that failed |

Add `--json` for scripts. States: `queued`, `running`, `pending` (waiting for you), `waiting` (no connection; resumes by itself), `paused`, `completed`, `rejected`, `cancelled`, or a failure such as `storage_failed`.

## Access policies: what the user sees

Policies are set by the root admin (`idrt enterprise zone policy`). On the Source:

- `idr connect` and `idr services` list only the services your zone allows.
- Asking for anything else fails:
  ```
  $ idr active lmstudio
  active failed: Failed to list models: IdrException(8/connection_refused): service not allowed for this Source's zone
  ```
- A policy change applies from your next session. Run `idr connect` again to see it; there's nothing to re-enroll.

## Revocation: what the user sees

When the admin revokes your device, or your whole zone (`idrt enterprise revoke`), your next session is refused by Presence:

```
$ idr connect
connect failed: … IdrException(9/signaling_failed): policy_denied: session request denied: Source identity or zone policy
```

- An already open REPL keeps working until it closes. The check happens when a session starts.
- Members of other zones, and other members of your zone (after a member-only revocation), are unaffected.
- There is no way to undo a revocation from the Source. Ask the admin:
  - **Device revoked:** run `idr logout --forget-device` (this drops the revoked key), then `idr login` and `idr enroll … --org <slug>`. The admin approves it as a new device.
  - **Zone revoked:** wait until the admin re-issues the zone (`idrt enterprise zone add`), then re-enroll the same way.

## Billing

Sources don't buy anything. Seats and subscriptions belong to whoever pays for the Target side:

| Mode | Pays | Where |
|---|---|---|
| Personal | You | `idrt billing` on your admin machine, or the portal's **Subscriptions** |
| Enterprise | The organization | Org owners/admins: `idrt billing` (portal for checkout). Users/roles: `idrt enterprise members` |
| Service Provider | The tenant's org or the provider | `idrt provider billing <tenant>` |

Each approved Source takes one seat. If the admin's approval fails with `device_seat_limit`, the organization needs another seat bundle (portal → shop) or must revoke an unused device.

## Troubleshooting

Start with `idr doctor` (add `--connect` to test the whole path). Exit codes: `0` ok, `1` failed, `2` sign-in needed, `3` connection or approval pending, `5` native library or configuration, `64` usage, `70` unexpected (rerun with `--verbose`). See [Common behavior](../README.md#common-behavior).

| Message | Cause | Fix |
|---|---|---|
| `… is waiting for Target Admin approval. Run enroll again after approval.` | Not approved yet | Ask the admin to approve, then rerun `idr enroll` |
| `The Target Admin rejected this Source device.` | The admin rejected it | Enroll again if that was a mistake |
| `You are not a member of <org>` (`enroll --org`) | Not invited, or invited under another email | The org owner adds you under **Members** in the portal |
| Enroll fails with `NOT_REGISTERED`, or the admin sees no pending request | The request went to your personal account | Rerun with `--org <slug>` |
| `This account has no Admin entity yet` / `ENTITY_NOT_FOUND` | No admin machine for that account or org yet | The admin runs `idrt … setup --role admin` first |
| Enroll or connect fails with `401` after a long break | Expired session | `idr login --force` |
| `policy_denied: session request denied…` | Your device or your zone was revoked, or your zone allows no services | Ask the admin (`idrt enterprise org` shows zone status) |
| `service not allowed for this Source's zone` | Your zone's policy doesn't include that service | Use an allowed service, or ask for a policy change |
| `target_not_registered: target not registered` | The Target is offline or the FQHN is wrong. Prefs may still point at an old Target. | Check the Target runs `idrt start`, then `idr connect <correct-fqhn>` |
| `source_unverified` | Session proof rejected: an old `idr_c_api` build, or this machine's clock is more than 2 minutes off | Rebuild `idr_c_api` (`--features native`); sync the clock |
| `policy_unavailable` | Presence couldn't reach billing's policy check | Admin: check `session_policy_url` and that `PRESENCE_SERVICE_TOKEN` matches in billing and Presence |
| `The chat REPL needs an interactive terminal.` | Run from a script or pipe, or with `--no-input` | Use `--prompt "…"` |
| `idr doctor` exits `5`, library `not found` | `idr_c_api` or `idr_dp` not found | Build them and copy them next to `idr`, or set `IDR_C_API_LIB` / `IDR_DP_LIB` |
| `cannot load …: a library it depends on is missing` | On Windows, `idr_c_api.dll` needs OpenSSL 3 and the VC++ runtime | See [Build and distribute](../README.md#build-and-distribute) |
| `source-agent is not running` (`idr transfer …`) | The Source agent isn't started, or `IDR_SOURCE_CONFIG` points at another config | Start `source-agent --config … run` and set `IDR_SOURCE_CONFIG` to the same file |
| Agent log: `Target refused peer binding; transfers disabled on this session` | The Target couldn't verify this Source: Presence runs without `PRESENCE_SERVICE_TOKEN`, or the device was revoked | Start Presence with the token; check the device in `idrt … devices` |
| Agent log: `DP identity file missing; continuing unenrolled` | `[dp].identity_path` is wrong, or the file was never exported | Redo [step 2](#2-save-this-devices-identity-for-the-agent) |
| `idr transfer send` stays `running` | The Target hasn't accepted yet, or the Target isn't in `[daemon].targets` | Ask the Target to accept; add the FQHN to `targets` and restart the agent |
| `accept --out …` refused | The folder doesn't exist or isn't inside `receive_dir` / `permitted_dirs` | Create it there, or add its parent to `permitted_dirs` |
| `Missing <target-fqhn>.` (exit `64`) | No Target given and nothing to prompt with | Pass the Target, or run in a terminal |
| `'C:\install' is not recognized…` on Windows | The Flutter `dart` launcher breaks on arguments with spaces when Flutter is installed in a path with spaces | Call `…\flutter\bin\cache\dart-sdk\bin\dart.exe` directly |

**Handing a machine to someone else:**

- Run `idr logout --forget-device`. A plain `logout` keeps the device key, and whoever signs in next on the same OS account would connect with it.
- Ask the admin to `idrt enterprise revoke <ski>` the old device, so its seat is freed and its certificate is dead on billing.

Several users on one machine (testing): give each its own `APPDATA` folder. Each folder then has its own session and device key.

Design notes:

- The CLI is thin: arguments, printing, REPL history and exit codes. Shared terminal code (output modes, prompts, errors, masking, checks) lives in [`idr_cli_core`](../idr_cli_core).
- The SDK owns sign-in, enrollment, the session proof, WebRTC, the catalog and chat.
