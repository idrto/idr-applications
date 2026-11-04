# idrt: the Target CLI

`idrt` runs a machine as an **IDR Target**: it publishes local services (Ollama, LM Studio, any HTTP/TCP endpoint) to approved Source devices through Presence, without opening an inbound port. The same CLI is the **admin** tool: it holds the organization's CA, approves machines, issues zone certificates, sets access policies and revokes credentials.

Source machines use the [`idr` CLI](../idr_sources_cli/README.md). For how the two fit together, see the [overview](../README.md).

Built on [`package:idr_target`](../sdks/idr_target). Plain `dart run`, no Flutter.

- [Role in the system](#role-in-the-system)
- [Install](#install)
- [Configuration](#configuration)
- [Commands](#commands)
- [Registration: Personal](#registration-personal)
- [Registration: Enterprise](#registration-enterprise)
- [Registration: Service Provider](#registration-service-provider)
- [File transfer](#file-transfer)
- [Access policies](#access-policies)
- [Revocation](#revocation)
- [Billing](#billing)
- [Troubleshooting](#troubleshooting)

## Role in the system

| Piece | Job |
|---|---|
| **Admin machine** (`idrt`, `--role admin`) | Holds the org's root CA key (and zone CA keys). Approves enrollments, issues zone certificates, signs zone policies, revokes. |
| **Target machine** (`idrt`, default role) | Runs `target-agent`, which registers with Presence and serves the configured services. Enforces each Source's zone policy per stream. |
| **Billing** (`:3000`) + **portal** (`:5173`) | Sign-in, organizations, subscriptions and seats. Records every issued credential and its status. |
| **Presence** | Brokers Source → Target sessions. Verifies the Source's certificate chain and asks billing which services it may use. |

One machine can be both admin and Target only in Personal mode. In Enterprise, keep the admin (root CA) machine separate.

## Install

From the repo root:

```bash
cd applications/apps/idr_target_cli
dart pub get
dart run bin/idrt.dart --help
```

Optional, to get a global `idrt` command:

```bash
dart pub global activate --source path .
```

Examples below write `idrt` for `dart run bin/idrt.dart`.

Native pieces, built once from `agents_engine/agent`:

```bash
cargo build --release -p target-agent --features webrtc
cargo build --release -p idr-dp-ffi
```

You get `target-agent.exe` and `idr_dp.dll` in `agents_engine/agent/target/release/`. Run from inside the repo, `idrt` finds both there; otherwise put them next to `idrt` or set `IDR_TARGET_AGENT` and `IDR_DP_LIB`. Run `idrt doctor` to check. To build a standalone `idrt` executable for other users, see [Build and distribute](../README.md#build-and-distribute).

Services that must be running (dev):

| Service | Start | Listens on |
|---|---|---|
| Billing | `cd Auth_repo/billing && npm run db:setup && npm run dev` | `http://127.0.0.1:3000` |
| Billing portal | `cd Auth_repo/billing-portal && npm run dev` | `http://localhost:5173` |
| Presence | `cd Servers/presence && IDR_CONFIG=config/presence.local.toml cargo run --bin idr-presence` | discovery `:8081`, QUIC `:14433` |

## Configuration

`--flavor dev|staging|prod` (default: prod for a release build, dev under `dart run`; see Flavors in `../README.md`) sets the endpoints and the state folder (`to.idr`, `to.idr-dev`, …). Environment variables override it:

| Variable | Default (dev flavor) | Purpose |
|---|---|---|
| `IDR_CONTROL_PLANE_URL` | `http://127.0.0.1:3000` | Billing / auth API |
| `IDR_BILLING_PORTAL_URL` | `http://localhost:5173` | Portal links |
| `IDR_TARGET_AGENT` | next to `idrt`, then `PATH`, then the repo build | Path to the agent binary |
| `IDR_DP_LIB` | next to `idrt`, then the repo build | Path to `idr_dp` (certificate crypto) |
| `IDR_DISCOVERY_URL` | `http://127.0.0.1:8081/.well-known/idr-presence.json` | Presence discovery |
| `NO_COLOR` | unset | Any value turns colors off |
| `APPDATA` (Windows) / `HOME` | OS default | Root of all local state (see below). Set it to run a second profile on one machine. |

Files:

| Path | Contents |
|---|---|
| `%APPDATA%/to.idr/idr_target/secure/auth.json` | Sign-in session, bound org, mode, **root and zone CA private keys** on an admin machine. Encrypted with DPAPI on Windows; plain JSON (mode 0600) elsewhere: protect it like a key. |
| `%APPDATA%/to.idr/idr_target/target.local.toml` | Agent config, rewritten on every `idrt start` |
| `%APPDATA%/to.idr/idr_target/identity.dp.json` | This Target's approved certificate |
| `%APPDATA%/to.idr/idr_target/entitlement.jwt` | Short-lived subscription token for Presence. Renewed every few minutes while running; the agent picks up the new one without restarting. |
| `%APPDATA%/to.idr/idr_target/transfers/` | File-transfer state and history |
| `%APPDATA%/to.idr/idrt/orgs.json` | Organizations this machine bound before (org picker) |

`idrt` and the Target GUI share this one Target: sign in, register or bind an org in either and the other sees it. Only one of them runs the agent at a time; starting a second one fails with `AGENT_ALREADY_RUNNING`.

`target.local.toml` is generated. The settings you may want to know about:

| Setting | Meaning |
|---|---|
| `[[services]] name / base_url` | From `idrt services add` |
| `[webrtc.policy] require_source_policy` | `true` in Enterprise: only Presence-verified, enrolled Sources may open streams, limited to their zone's services |
| `[telemetry] metrics_listen` | `127.0.0.1:9091`. Fixed, so run one agent per machine. |

Presence needs two settings for zone policies:

- `session_policy_url = "http://127.0.0.1:3000/api/v1/machine-authn/session-policy"` under `[auth]` in its TOML.
- The same `PRESENCE_SERVICE_TOKEN` value set in billing's `.env` and in Presence's environment.

## Commands

Shared:

| Command | Does |
|---|---|
| `idrt login [--force]` | Sign in through the browser |
| `idrt logout` | Sign out and forget this machine's host registration and bound org |
| `idrt status` | Account, mode, role, subscription, host, enrollment and agent state |
| `idrt doctor` | Check config, billing and Presence reachability, sign-in, plan, host, identity, `target-agent`, `idr_dp`, the agent config (via `target-agent doctor`) and whether the agent runs |
| `idrt start` | Write the agent config and run `target-agent` in the foreground (Ctrl+C stops). Prints the served FQHN, agent path, Presence and services once running. |
| `idrt services list` | Configured services |
| `idrt services add <name> <url> [--type http\|tcp] [--tls]` | Publish a local service |
| `idrt services remove <name>` | Stop publishing it |
| `idrt transfer peers\|send\|list\|status\|accept\|reject\|pause\|resume\|cancel\|retry-failed` | Receive files from Sources and send to them, through the running agent. See [File transfer](#file-transfer). |
| `idrt billing [--status]` | Subscription state, then open the portal |
| `idrt subscribe [--no-open]` | Straight to checkout |

Per mode (`idrt <mode> --help` lists all):

| Personal | Enterprise | Service Provider |
|---|---|---|
| `personal setup [--host h]` | `enterprise setup --org o [--role admin\|target] [--host h] [--zone z]` | `provider setup --org o` |
| `personal register <host>` | `enterprise register <host> [--zone z]` | `provider tenant add\|list\|remove` |
| `personal pending` | `enterprise pending` | `provider register <host> --tenant t` |
| `personal approve\|reject <id>` | `enterprise approve <id> [--zone z]`, `reject <id>` | `provider pending`, `approve\|reject <id>` |
| | `enterprise zone add <zone> [--name n]` | `provider billing <tenant> [--buy]` |
| | `enterprise zone policy <zone> --allow s[,s]` | `provider domain add\|verify\|list\|remove` |
| | `enterprise org`, `devices`, `members [invite\|role\|remove]` | |
| | `enterprise zone list`, `zone show [<zone>]`, `zone invite` | |
| | `enterprise revoke <ski\|zone> [--reason r]` | |

Service names matter: a zone policy allows services **by name**, so call them what the policy will say (`ollama`, `lmstudio`).

Global flags (`--json`, `--no-color`, `--no-input`, `--verbose`), prompts and exit codes are shared with `idr`: see [Common behavior](../README.md#common-behavior). Commands that need a value you left out ask for it in a terminal (`services add`, `<mode> register`, `enterprise|provider setup --org`).

## Registration: Personal

One user and their own machines. Their subscription pays, and the first machine is the admin.

1. **Sign in.**
   ```bash
   idrt login
   ```
   Result: `Signed in as you@example.com.`
2. **Set up and register this machine.**
   ```bash
   idrt personal setup --host laptop
   ```
   - Without a Personal subscription, the portal opens at checkout and the command exits `4`. Pay, then run it again.
   - Result: `This machine is the Personal admin for you@example.com.` then `Registered laptop--you@example.com.idr.to.` The first machine for your email becomes the admin.
   - If it prints `Approve it here`, approve its own enrollment:
     ```bash
     idrt personal pending
     idrt personal approve <id>
     ```
     Otherwise it prints `Next: idrt start`.
3. **Publish a service and start.**
   ```bash
   idrt services add ollama http://127.0.0.1:11434
   idrt start
   ```
   Result: `Serving laptop--you@example.com.idr.to. Ctrl+C to stop.`
4. **Add another Target machine.**
   - On the new machine:
     ```bash
     idrt login
     idrt personal setup --host desktop
     ```
     Result: `Waiting for approval…`
   - On the admin machine:
     ```bash
     idrt personal pending
     idrt personal approve <id>
     ```
     Result: `Approved <id>.` Then run `idrt start` on the new machine.
5. **Activate a Source.** On the Source, run `idr login` and `idr enroll laptop--you@example.com`. On the admin machine, run `idrt personal pending` and `idrt personal approve <id>`. See the [Source README](../idr_sources_cli/README.md#registration-personal).

## Registration: Enterprise

An organization pays. A **root admin** machine holds the org CA and issues one certificate per **zone** (for example, a department). Each member's certificate is signed by their zone, so the chain is member → zone → root.

Before you start, in the billing portal:

- Create the organization (Switch account → create organization). Note its **slug**.
- Buy the **Enterprise** plan for it.
- Invite users under **Members**. Owners and admins can register machines. Members can only enroll Sources.

### 1. Create the root admin

```bash
idrt login
idrt enterprise setup --org acme --role admin --ca root
```

Result:
```
Organization: acme (acme), you are owner.
This machine is an Enterprise admin (root CA) for acme.
```

The root CA key is now in this machine's `auth.json`. Back it up. Losing it means a dev reset (see [Troubleshooting](#troubleshooting)).

### 2. Create zones

On the root admin machine:

```bash
idrt enterprise zone add zone-a --name "Zone A"
idrt enterprise zone add zone-b --name "Zone B"
```

Result, per zone:
```
Zone zone-a added with a certificate under the root.
  zone CA SKI: pd4jlslKzZmr0jOZfhG8cSR88i8ied0uKHHNsY_byRI
```

Check:
```bash
idrt enterprise org
```
```
zones:
  zone-a           Zone A
    certificate pd4j…, issued 2026-10-23, registered on billing, key on this machine
    policy: no policy (all services), v1
```

Zone paths can nest (`fin`, then `fin.apac`): add the parent first.

### 3. Register Targets

On each Target machine (signed in as an org owner or admin):

```bash
idrt login
idrt enterprise setup --org acme --role target --host gpu-box
```

Result: `Registered gpu-box--you@acme.com.idr.to.` then `Waiting for approval.`

On the root admin machine:

```bash
idrt enterprise pending
idrt enterprise approve <id>
```

Result: `Approved <id>.` This takes one seat. Back on the Target:

```bash
idrt services add ollama http://127.0.0.1:11434
idrt services add lmstudio http://127.0.0.1:1234
idrt start
```

Result: `Serving gpu-box--you@acme.com.idr.to. Ctrl+C to stop.` One Target can serve several zones: the zone policy decides who reaches which service.

### 4. Register users into a zone

The user enrolls their Source device with `idr enroll <target-fqhn> --org acme`; see the [Source README](../idr_sources_cli/README.md#registration-enterprise). Then, on the root admin machine:

```bash
idrt enterprise pending
idrt enterprise approve <id> --zone zone-a
```

Result: `Approved <id> under zone zone-a.` Their certificate is signed by zone-a's CA and takes one seat. Without `--zone`, the device is signed directly by the root and gets no zone.

## Registration: Service Provider

You run Targets for customer **tenants** and pay per Target seat (`idr_sp_target`). A tenant is billed to its own billing org (you must be owner or admin there) or, by default, to your provider org.

1. **Register the provider.**
   ```bash
   idrt login
   idrt provider setup --org myprovider
   ```
   Result: `Service Provider: myprovider (myprovider), you are owner.`
2. **Onboard customer tenants.**
   ```bash
   idrt provider tenant add acme --name "Acme Corp" --org acme   # Acme's org pays
   idrt provider tenant add demo                                 # your org pays
   idrt provider tenant list
   ```
3. **Register a Target for a tenant** (one machine serves one tenant):
   ```bash
   idrt provider register cam01 --tenant acme
   ```
   - If the tenant's org is out of seats, the portal opens at checkout and the command exits `4`.
   - Result: `Registered cam01--you@….idr.to.`
4. **Approve and start.** Any provider machine can approve; Service Provider mode has no admin machine.
   ```bash
   idrt provider pending
   idrt provider approve <id>
   idrt services add ollama http://127.0.0.1:11434
   idrt start
   ```
5. **Manage the tenant's users.**
   - Users belong to the tenant's billing org: invite them under **Members** in the portal for that org.
   - They enroll with `idr enroll <target-fqhn> --org <tenant-org>`, and you approve them with `idrt provider approve <id>`.
   - Zones, zone policies and revocation are Enterprise features, so they aren't available in Service Provider mode.
6. **Tenant billing.**
   ```bash
   idrt provider billing acme --buy
   ```
   This opens the portal for that tenant's org, at seat checkout.

The tenant list is stored only on this machine; billing has no tenant API.

### Custom domains

A tenant can reach its Target at its own hostname (`app.customer.com`) with a Let's Encrypt certificate. Run these on the tenant's Target machine, as an owner or admin of the tenant's billing org.

1. **Add the domain.**
   ```bash
   idrt provider domain add app.customer.com
   ```
   Result: the DNS record to create, then the first check:
   ```
   Added app.customer.com to cam01--you@sp.com.idr.to.
   Create this DNS record at the domain's DNS provider:
     app.customer.com  CNAME  cam01--you-40sp-2ecom.idr.to
   Not verified yet: app.customer.com has no CNAME record. Add CNAME …
   ```
   The CNAME target is the DNS-encoded form of the Target's name; copy it exactly.
2. **Create the CNAME** at the customer's DNS provider. Use a subdomain: an apex domain (`customer.com`) can't hold a CNAME.
3. **Verify.**
   ```bash
   idrt provider domain verify app.customer.com
   ```
   Result: `Verified: app.customer.com points to this Target.` It exits `1` while not verified, so a script can wait on it. Billing also re-checks pending domains every 10 minutes for 7 days.
4. **Restart the agent** (`idrt start`). It requests the certificate from Let's Encrypt and answers the HTTP-01 challenge itself. No nginx is needed for issuance.
5. **Check the certificate.**
   ```bash
   idrt provider domain list
   ```
   ```
   app.customer.com             verified
     CNAME → cam01--you-40sp-2ecom.idr.to
     certificate: issued, expires 2027-01-20, renews 2026-12-21
   ```

What happens afterwards:

- **Renewal:** the agent renews 30 days before expiry, on its own.
- **Re-checks:** billing re-checks verified domains every 6 hours. If the CNAME is gone on two checks in a row, the domain becomes `failed` and stops routing to this Target.
- **Development:** the dev flavor (`idrt --flavor dev`) uses Let's Encrypt's staging server; its certificates aren't trusted by browsers.
- **Remove:** `idrt provider domain remove app.customer.com` stops routing within 5 minutes (Presence's cache); restart `idrt start` to drop the certificate request.
- **Status file:** certificates and each domain's `acme-status.json` live in `%APPDATA%/to.idr/idr_target/acme/certs/<domain>/` (shared with the Target GUI).
- **HTTPS still needs nginx:** serving HTTPS on the custom domain needs an nginx on this machine that uses that certificate. Issuance doesn't.

## File transfer

A Target exchanges files and folders with the Sources connected to it, over the same peer-to-peer connection as its services. File transfer is on by default; there is nothing to configure.

- Only **verified** Sources can transfer: a Source shows up once Presence has checked its certificate. Presence must run with `PRESENCE_SERVICE_TOKEN` set.
- Interrupted transfers resume where they stopped, even after either side restarts.
- Every file is checked by SHA-256 before it appears under its real name.

The Source side needs its **Source agent** running (`source-agent run`); see the [Source README](../idr_sources_cli/README.md#file-transfer).

### With the CLI

`idrt start` must be running (in another terminal); `idrt transfer …` talks to that agent.

**See who is connected:**

```bash
idrt transfer peers
```

Prints a `source` / `connection` table: each connected Source's **SKI** (device ID) and whether the connection is direct or relayed. A Source is listed only while its agent is connected. If the list is empty, see [Troubleshooting](#troubleshooting).

**Receive from a Source.** Sources send with `idr transfer send --target <this-target>`. Each offer waits for you:

```bash
idrt transfer list                              # state "pending", with the file names and size
idrt transfer accept <id>                       # into the receive folder
idrt transfer accept <id> --out C:/Users/you/Downloads/IDR/project-x
idrt transfer reject <id>
```

- The receive folder is `Downloads/IDR` in your home folder.
- `--out` must be an existing folder inside the receive folder; anything else is refused.
- Offers you don't answer expire after a while and are refused.

**Send to a Source:**

```bash
idrt transfer send --source <ski> --file report.pdf --file photo.jpg
idrt transfer send --source <ski> --dir ./dataset
```

- `<ski>` comes from `idrt transfer peers`.
- `--file` can be repeated; `--dir` sends a whole folder, including subfolders, empty folders and empty files.
- The Source's user accepts it with `idr transfer accept <id>`. Until then the transfer shows as `running`.

**Manage transfers:**

| Command | Does |
|---|---|
| `idrt transfer list` | All transfers and pending offers |
| `idrt transfer status <id>` | State, contents, connection path and progress |
| `idrt transfer pause <id>` / `resume <id>` | Pause or continue |
| `idrt transfer cancel <id>` | Stop and remove the partial data |
| `idrt transfer retry-failed <id>` | Re-send only the files that failed |

Add `--json` for scripts. States: `queued`, `running`, `pending` (waiting for you), `waiting` (no connection; resumes by itself), `paused`, `completed`, `rejected`, `cancelled`, or a failure such as `storage_failed`.

### With the Target GUI

Start the Target, then open the **Transfers** tab:

- **Send…** picks a connected Source (listed as direct or relayed), then **Choose files…** or **Choose folder…**. If it says *No Source is connected right now*, the Source's agent isn't running or isn't verified yet.
- Incoming offers show **Accept**, **Accept to…** (pick a folder under your home folder) and **Reject**.
- Each transfer shows its progress and can be paused, resumed or cancelled. To re-send only failed files, use `idrt transfer retry-failed <id>`.

Accepted files land in `Downloads/IDR` unless you chose another folder.

## Access policies

Enterprise only, on the root admin machine. A zone's policy lists the services its members may use, by service name. Without a policy, members may use every service.

```bash
idrt enterprise zone policy zone-a --allow ollama
idrt enterprise zone policy zone-b --allow lmstudio
idrt enterprise zone policy zone-c --allow ollama,lmstudio
idrt enterprise zone policy zone-a --allow "*"        # back to all services
```

Result: `Zone zone-a may use: ollama (policy v2).`

How it is enforced:

1. The policy is part of the zone certificate's signed credential. Setting it re-signs the credential and bumps its version. Members don't re-enroll.
2. When a Source opens a session, Presence asks billing for that Source's zone and allowed services, then signs them into the session offer.
3. The Target (with `require_source_policy = true`) shows the Source only allowed services. It refuses any other stream with `service not allowed for this Source's zone`.

Changes apply from each Source's **next** session.

## Revocation

Enterprise only, by the org owner, on the root admin machine.

```bash
idrt enterprise revoke <ski> --reason lost-laptop   # one member or Target
idrt enterprise revoke zone-b                       # a whole zone
```

Result: `Revoked zone zone-b (certificate z_6Y…, reason other). Its members are denied from their next session.`

Zone SKIs are listed by `idrt enterprise zone list` / `org`. Member and Target SKIs are listed by `idrt enterprise devices` (org owner; from billing). The Target log also prints `ski=…` when it refuses a stream.

What happens afterwards:

| Revoked | Effect |
|---|---|
| A member | Its next session fails at Presence with `policy_denied`. Other members of the zone are unaffected. Its seat is released. |
| A zone | Every member of that zone fails with `policy_denied`, including members whose own certificate is still active. Other zones are unaffected. The zone's CA key is deleted from the admin machine and `org` shows `no certificate`. |
| A Target | Billing marks it revoked, refuses to renew its certificate and releases its seat. |

Notes:

- Sessions that are already open keep running until they close. Revocation is checked when a session opens.
- To bring a zone back, run `idrt enterprise zone add zone-b`. It issues a **new** zone certificate, and each member must re-enroll and be approved again with `--zone zone-b`.
- Members of a revoked zone keep their seats until you revoke them individually.
- `revoke` refuses this machine's own root CA.

## Billing

| Command | Opens |
|---|---|
| `idrt billing` | `/subscriptions` if active, else `/shop/<plan>` checkout |
| `idrt billing --status` | Prints the state only. Exits `4` when the subscription is missing or expired. |
| `idrt subscribe` | Checkout. `--no-open` prints a signed-in link instead. |
| `idrt enterprise members` | In the CLI (list / invite / role / remove). Does not open the portal. |
| `idrt provider billing <tenant> [--buy]` | That tenant's org; `--buy` goes to seat checkout |

- Enterprise links open the portal with the org preselected (`/auth/handoff?slug=<org>`).
- Only owners and admins see the org's billing. Members are told that billing is handled by owners and admins.

**Seats:**

- Every approved machine takes one seat: Targets and Sources alike.
- An Enterprise bundle has 5 seats. Buy more bundles in the portal.
- Revoking a member or Target frees its seat.
- Commands that need a paid plan (`setup`, `register`, `approve`, `start`) stop with exit `4` and send you to the portal.

## Troubleshooting

Start with `idrt doctor`. Exit codes: `0` ok, `1` failure, `2` not signed in, `3` unreachable, `4` billing, `5` configuration or native dependency, `64` usage, `70` unexpected (rerun with `--verbose`). See [Common behavior](../README.md#common-behavior).

| Message | Cause | Fix |
|---|---|---|
| `Device seat limit reached… [device_seat_limit]` (approve) | All seats used | Buy another bundle (`idrt billing`), or revoke an unused machine. One Target can serve several services instead of one Target each. |
| exit `4`, portal opens | No active subscription for the bound org | Pay in the portal, rerun |
| `app.customer.com has no CNAME record` | The record isn't there yet, or it's an apex domain | Create the CNAME printed by `domain add` on a subdomain; new records can take a few minutes |
| `app.customer.com points to X, expected Y` | The CNAME points somewhere else (often an old host) | Change it to the target shown (`domain list`), then `domain verify` |
| `… is already verified on another Target` (`DOMAIN_TAKEN`) | Another Target still holds the domain and its CNAME still points there | Re-point the CNAME at this Target; this Target takes it over on the next verify |
| `certificate: failed: … rejectedIdentifier` | Let's Encrypt won't issue for that name (not a public domain) | Use a real public hostname |
| `certificate: failed: … authorization invalid` | Let's Encrypt couldn't fetch the challenge through Relay | Check `domain list` says verified, the agent is running (`idrt start`), and Presence has `domain_alias_url` set |
| `You are a member of <org>. Ask an owner to make you an admin` | Members can't register Targets | Owner: `idrt enterprise members role <email> admin` |
| `<org> has an active X subscription, not Enterprise` | The org bought another plan | Use the matching mode, or change the plan in the portal |
| `Only the root CA admin machine issues zone certificates` / `signs zone policies` | Run on a Target or intermediate machine | Run on the machine set up with `--role admin --ca root` |
| `Zone zone-a has no certificate on this machine` (`approve --zone`) | Zone not issued here, or revoked | `idrt enterprise zone add zone-a` on the root machine |
| `credential-revoke failed (404): Device not found` | Wrong SKI | Copy the SKI exactly; it is case-sensitive |
| `That is this machine's root CA` | `revoke` was given the root SKI | Not allowed. To start over, use the dev reset below. |
| `target-agent binary not found` / doctor `target-agent  not found` | Not next to `idrt`, not on `PATH`, not in the repo build, and `IDR_TARGET_AGENT` unset or wrong | Build it; put it next to `idrt` or set the full path |
| doctor: `target-agent … cannot start: a DLL it needs is missing` | OpenSSL 3 or the VC++ runtime is missing (Windows) | See [Build and distribute](../README.md#build-and-distribute) |
| `discovery signature verify failed; insecure_dev continuing` | Presence was restarted with a new signing key | Harmless in dev; in production, update the discovery key |
| A second agent on the same machine won't start | Both bind the metrics port `127.0.0.1:9091` | Run one agent per machine; give it all the services |
| `target-agent is not running` (`idrt transfer …`) | `idrt start` isn't running, or another Target agent on this Windows account holds the local control pipe | Run `idrt start`. With the GUI's Target also running, stop one of them for transfers (one control pipe per Windows user). |
| `idrt transfer peers` is empty / GUI says *No Source is connected right now* | No Source agent is connected, or Presence couldn't verify it (no `PRESENCE_SERVICE_TOKEN`) | Start `source-agent run` on the Source with this Target in `[daemon].targets`; start Presence with the token |
| `accept --out …` refused | The folder doesn't exist or isn't inside the receive folder | Create it under `Downloads/IDR` |
| A transfer stays `running` | The other side hasn't accepted yet | Accept it there (`idr transfer accept <id>`) |
| Can't rebuild `idr_dp.dll` (file in use) | A running app (for example `target_app`) has it loaded | Close the app, or point `IDR_DP_LIB` at another build |
| `'C:\install' is not recognized…` on Windows | The Flutter `dart` launcher breaks on arguments with spaces when Flutter is installed in a path with spaces | Call `…\flutter\bin\cache\dart-sdk\bin\dart.exe` directly |

**Dev reset** (root created on the wrong package, or the root key was lost):

```bash
cd Auth_repo/billing
npm run dev:reset-machine-authn -- --org <slug> --yes
idrt enterprise setup --org <slug> --role admin --ca root --reset-local-ca
```

This deletes the org's machine credentials, devices and machine seats. Use it in development only.

Code layout: `lib/core/` holds shared config, billing, device enrollment, `doctor` and the common commands. `lib/modes/<mode>.dart` holds each mode's command group. Terminal output, JSON, prompts, errors and exit codes come from [`idr_cli_core`](../idr_cli_core).
