# Enterprise zones, registration, and service access

**Status:** living spec. Org users/roles/invites in `idrt` (no browser) added 2026-10-26.

This document records **desired** Enterprise behavior, **current** implementation (with file evidence), existing tests that were run, gaps, and a prioritized fix list. Wait for approval before implementing.

Related user docs: [idrt Enterprise](../idr_target_cli/README.md#registration-enterprise), [idr Enterprise](../idr_sources_cli/README.md#registration-enterprise).

---

## Desired vs current (summary)

| Topic | Desired | Current (confirmed in code) |
|---|---|---|
| Entity identity | Email **or** unique name (brand/domain); DNS proof later | Kickstart `entityId` defaults to **session email**. Any unused string can be passed, but CLI does not offer a named-entity option. No domain/brand verification. |
| Entity FQHN | e.g. `acme.idr.to` | Entity is **not** a Presence Target. Connectable names are machines: `{host}--{entity}.idr.to`. |
| Zone FQHN | e.g. `fin.acme.idr.to` | Zone is a **path key** (`fin`, `fin.apac`) + zone CA. Not registered with Presence. |
| Zone admin | Holds zone CA; reviews/signs CSRs for that zone | **Implemented (2026-10-27).** `zone invite` sets the role on billing; the zone admin's machine holds its own root-signed zone key and approves only its zone. |
| Source zone selection | Path A (no zone → root inbox) and Path B (pick zone → zone admin) | Both: no `--zone` → owner's inbox, zone picked at approve; `idr enroll --zone fin` → fin's admins (and owner). |
| Host uniqueness | Unique **per zone** | Unique **per entity** (`machine_seats` `entity_id` + `host`). |
| Machine FQHN | Distinct per zone so `gpu-box` can repeat | Live: `{label}--{entityId}.idr.to` with `entityId` usually email. Zone not in the name. |

**Verdict:** desired Path B, zone-scoped host names, named entity as a first-class CLI option, and zone-admin CSR signing are **not implemented**. Several unit tests of the *current* model pass.

---

## 1. Root admin and entity registration

### Desired

When creating the root admin:

- **Email-based entity:** `entityId` = root admin email (Personal-like locator).
- **Named entity:** unique brand or domain (e.g. `acme`, `acme.com`). Ownership verification (DNS TXT / CNAME) is **later**.

Constraints that any option must satisfy:

- Global uniqueness of `dp_entity_id` (`paying_parties`, unique when not null).
- Org **owner** only may `registerMachineAuthn` (`OWNER_REQUIRED`).
- JWT org must match paying party (`ORG_MISMATCH`).
- Hosts/enroll: `entityId` must be session email **or** that party’s `dpEntityId` (`assertEntityOwned` in `Auth_repo/billing/src/routes/v1/hosts.routes.ts`).
- FQHN: `{host}--{entityId}.idr.to` (`POST /api/v1/hosts`).
- Presence `canonicalize` allows `@ . _ -` in entity (`Servers/presence/src/protocol/fqhn.rs`).

### Current

| Step | Command / API | What happens |
|---|---|---|
| Bind org | `idrt enterprise setup --org acme --role admin` | Billing org slug `acme`; not `entityId`. |
| CA | `ensureAdminCa(package: enterprise)` | `entityId` = `session.email` (`idr_target.dart` `ensureAdminCa`). |
| Kickstart | `POST .../kickstart-entity` | Registers Machine AuthN with that `entityId`. 409 if entity exists. |
| Named entity | — | **No CLI flag.** Passing a custom `entityId` into kickstart is possible at the HTTP layer if the caller is owner and the name is free. **Not proven unique vs email collisions** beyond DB unique. |
| Brand | `--brand` | Local org-graph display (`EnterpriseOrgManager`). Not `dpEntityId`. |
| Domain verify | `idrt provider domain *` | Custom **Target alias**, Service Provider. Does not claim entity name. |

**Safe to support both later?** Yes if: (1) owner-only kickstart stays, (2) `dp_entity_id` unique, (3) named entity is DNS-safe for Presence (`acme.com` OK; spaces not), (4) hosts `assertEntityOwned` includes named `dpEntityId` (already does), (5) Sources enroll against `{host}--{namedEntity}` not the admin email. **Not safe today** to treat `acme.idr.to` as a connectable Target — nothing registers it.

---

## 2. Zones and zone admins

### Desired

- Root creates zones under the entity (`fin`, nested `fin.apac`).
- Optional display FQHN `fin.acme.idr.to` is **catalog**, not Presence, until an alias layer exists.
- Root **invites** a zone admin.
- Zone admin: list pending for that zone, approve/reject, **sign CSR with zone CA**.
- Root: may still approve/sign for any zone (override).

### Current permissions

| Action | Who (code) | Evidence |
|---|---|---|
| `zone add` | Root CA admin machine only (`enterpriseCaRole == root`) | `idrt/lib/modes/enterprise.dart` `_ZoneAdd` |
| Issue zone CA | Same machine; keys in `auth.json` | `EnrollmentManager.issueZoneAuthority` |
| `zone policy` | Root admin machine | `idrt` README; re-signs zone credential |
| `zone invite <path> <email>` | Admin machine; **local list** | `EnterpriseOrgManager.inviteZoneAdmin`; `remoteSyncAvailable => false` |
| `approve --zone fin` | **Same root machine** (loads `loadZoneCa`) | `EnrollmentManager.approve` |
| Portal owner/admin/member | Org roles | Members enroll Sources; owners/admins register Targets / billing |

### Org users and roles (CLI, no browser)

**Desired / required for the first in-app implementation:**

- Entity `acme.idr.to` is **not** a Presence Target. Creating the entity (setup + CA) does **not** connect any machine to Presence. Only `idrt enterprise register <host>` → `{host}--{entity}.idr.to` plus `idrt start` registers that box as a Target.
- Root admin **views and manages org users and roles inside `idrt`**. Billing still stores membership; the CLI calls Better Auth (`list-members` / `invite-member` / `update-member-role` / `remove-member`) with the existing session cookie (same APIs as the portal).
- Root admin **invites by email from the CLI**. No browser, no portal handoff. Invitee still signs in (email from billing) and can `idr enroll`; they do not need the admin to open `/members`.
- `idrt enterprise members` **must not** open the billing portal. Checkout / `idrt billing` may still open a browser (already implemented; that stays).
- Roles: `owner` (org creator, not assigned via invite), `admin`, `member`. Invite and role-change offer `admin` | `member` only (same as the portal).
- Owners and org admins may invite / change role / remove. Members may list if billing allows; otherwise the CLI prints the server error.

**Commands:**

```text
idrt enterprise members
idrt enterprise members invite <email> [--role member|admin]
idrt enterprise members role <email> <admin|member>
idrt enterprise members remove <email>
```

`zone invite` remains zone-admin **label** on this machine (CA still local). Org membership is the billing invite above.

**Does current code support desired zone-admin signing?** **No.** Invite does not export zone CA, does not restrict inbox by zone, does not authorize a second machine to `signCsr`.

---

## 3. Source registration paths

### Desired Path A (no zone)

1. Source registers host name → root inbox.
2. Root approves and signs CSR (entity root CA).
3. Root **may later assign** the machine to a zone.
4. Policy then follows that zone (or root `*` if unsigned by a zone CA — see session-policy).

### Desired Path B (select zone)

1. Source selects existing zone.
2. CSR goes to **that zone’s** admin.
3. Zone admin signs with zone CA.
4. Machine is a member of that zone.

### Current (single path)

1. `idr enroll <target-fqhn> [--org slug] [--label host]`
2. `SourceIdentityManager.enroll`: `entityId` from Target FQHN; `host = {label}--{entityId}`; `kind=machine_source`; **no zone field**.
3. Pending until `idrt enterprise approve <id> [--zone key]`.
4. Without `--zone`: root CA signs; `sessionPolicy` issuer is not `zone_authority` → `zone=null`, `allowedServices` defaults toward `*`.
5. With `--zone`: zone CA signs; chain leaf→zone→root; policy from zone credential.

There is **no** “assign to zone after root-signed approve” API. Re-enroll + approve `--zone` would be a new device/SKI unless a migrate/re-sign path is added.

### States (current)

| State | Meaning |
|---|---|
| pending | `enroll-create` done; pull pending |
| approved | leaf/chain/credential stored; Source may connect with proof |
| rejected | pull `StateError` → `ENROLLMENT_REJECTED` |
| timeout | `ENROLLMENT_PENDING` (re-run enroll) |

Private key never leaves the Source. Admin only sees CSR + public JWK + SKI.

### Failure cases (current)

- Bad Target FQHN (no `--`) → `ENROLL_FAILED`.
- Wrong `--org` → request not in org inbox.
- Unknown `--zone` on approve → CLI usage error if zone CA missing locally.
- Source cannot select a nonexistent zone (no flag to abuse).

---

## 4. Host name uniqueness and FQHN

### Desired

- Unique **within a zone** (and at root as its own namespace).
- `gpu-box` in `fin` and `gpu-box` in `legal` both OK if FQHNs differ and routing works.

### Expected FQHN (this spec — not live)

Keep Presence grammar `{left}--{entity}.idr.to` (do not use a single hyphen as the locator):

| Machine | FQHN |
|---|---|
| Root-level Target/Source | `{label}--{entity}.idr.to` e.g. `mc2--acme.idr.to` |
| Zone-level | `{label}.{zone}--{entity}.idr.to` e.g. `gpu-box.fin--acme.idr.to` |

`parseMachineHost` / `validate_host_path` already allow **dotted** left-hand labels. Seat uniqueness must then key off the **full** host string (or entity+zone+label), not `gpu-box` alone.

### Current FQHN (live)

- Target: `{hostLabel}--{entityId}.idr.to` (`hosts.routes.ts`). `hostLabel` regex: **no dots**.
- Source: `{sanitizedLabel}--{entity}` (`source_identity_manager.dart`).
- GUI helper `EnterpriseFqhn.build`: `{host}.{zone...}--{brand}.idr.to` — **not** used by `idrt register` / Presence.
- Seats: `isActiveHostTaken(entityId, [hostLabel, verifiedFqhn])` — **entity-wide**.

### Routing / TLS / DNS (current)

- DNS wildcard `*.idr.to` → Relay. Application mapping is **exact** Presence registry lookup (`target_not_registered` if unknown).
- Native TLS: Relay wildcard; not Let’s Encrypt for `*.idr.to`.
- CSR CN/SAN: machine FQHN + SKI URI.
- Source connect: `canonicalPresenceFqhn` then Presence `lookup_target_for_request`.

**Incompatibility:** same label in two zones is **rejected** (or second seat conflict) on the live path because names collide as `gpu-box--entity`.

---

## 5. Scenario A — Root-level + Ollama

### Planned commands (desired / current CLI)

```text
idrt login
idrt enterprise setup --org <slug> --role admin --ca root
# entityId today = login email; named entity not in CLI
idrt enterprise register gpu-box
idrt enterprise approve <id>          # self-approve Target if admin machine
idrt services add ollama http://127.0.0.1:11434
idrt start
# Source:
idr login
idr enroll gpu-box--<entity> --org <slug> --label alice-laptop
idrt enterprise approve <source-id>   # no --zone
idr enroll
idr connect gpu-box--<entity>
idr active ollama
```

### Expected

Target online; Source mTLS/proof; session-policy allow; Ollama listed and usable.

### Actual (this environment)

**Not executed.** Missing live Billing, portal, Presence, paid Enterprise org, running Ollama, and two enrolled machines.

Closest passing units: Source enroll mock (`source_identity_manager_test.dart`); session-policy (`machine-authn-session-policy.test.ts`); `idrt` CLI smoke (`cli_test.dart`).

---

## 6. Scenario B — Zone admin + both Source paths

### Planned (desired)

```text
idrt enterprise zone add fin
idrt enterprise zone invite fin zone-admin@acme.com
# zone admin on another machine: obtain zone CA — NOT IMPLEMENTED
idrt services add ollama … && idrt start   # Target in zone or serving all zones
# Path A: idr enroll … (no zone); root approve; later assign zone — assign not implemented
# Path B: idr enroll … --zone fin — flag not implemented
idrt enterprise approve <id> --zone fin     # current Path-B substitute: root signs as zone
```

### Expected vs actual

| Step | Expected | Actual |
|---|---|---|
| Zone `fin.acme.idr.to` | Catalog/DNS name | Zone key `fin` only |
| Invite zone admin | Real signing authority | Local email label |
| Path A then assign zone | Re-sign / move | Missing |
| Path B Source `--zone` | Zone inbox | Missing |
| `approve --zone` on root box | Zone CA sign | **Works** (unit: `zone_authority_test.dart`) |
| Service access | Zone policy | `sessionPolicy` + Target `require_source_policy` (Enterprise) |

**Not executed E2E** (same prerequisites as A).

---

## 7. Negative and boundary tests

| Requirement | Current support | Existing test |
|---|---|---|
| Duplicate host **same zone** | Duplicate host **same entity** refused | Seat SQL / host routes (no dedicated “per zone” test) |
| Same host **different zones** | **Not allowed** live | **Gap** — would fail if asserted |
| Unauthorized cannot create zones | CLI: not root CA machine | CLI usage; billing owner for Machine AuthN |
| Zone admin cannot manage other zone | N/A (no real zone admin) | **Gap** |
| Bad/expired cert | Presence proof + `certificate_mismatch` | session-policy tests (leaf PEM match) |
| Source + nonexistent zone | No Source zone flag | **Gap** for Path B |
| Pending/rejected ≠ approved | Source throws; no credential | `source_identity_manager_test` (pending then approved) |
| Entity identity collision | DB unique + kickstart 409 | kickstart HTTP 409 handling |
| Root vs zone machine resolve | Same FQHN shape; zone in credential | `zone_members_test.dart` (listing, not Presence) |
| Service policy | Zone ACL ∩ device ACL | `machine-authn-session-policy.test.ts` |
| Compat with naming change | Old `{label}--{email}.idr.to` must keep SKI | **Gap** (migration tests) |

---

## 8. Component map

| Area | Code | Tests |
|---|---|---|
| Entity kickstart | `enrollment_manager.dart` `ensureAdminCa`; billing `register.service.ts`; `delegate-permissions.routes.ts` | `idr_target/test/kickstart_test.dart` |
| Host register / FQHN | `hosts.routes.ts`; `registration_manager.dart` | registration/host unit tests in billing (not re-run all) |
| Zone CA / approve `--zone` | `issueZoneAuthority`, `approve` | `idr_target/test/zone_authority_test.dart` |
| Local zone graph / invite | `enterprise_org_manager.dart` | (thin; invite not billed) |
| Source enroll | `source_identity_manager.dart`; `apps/idr_sources_cli/lib/commands/enroll.dart` | `idr_source/test/source_identity_manager_test.dart` |
| Host uniqueness | `machine-seat.repository.ts` `isActiveHostTaken` | gap for zone-scope |
| Session policy | `session-policy.service.ts`; Presence `session_policy.rs` | `machine-authn-session-policy.test.ts` |
| FQHN parse | `fqhn.rs`; `names.ts` `parseMachineHost`; `entityIdFromFqhn` | `names.test.ts`; Presence fqhn tests (not re-run cargo here) |
| CLI surface | `idrt` enterprise commands; `idr` enroll | `apps/idr_target_cli/test/cli_test.dart`, `apps/idr_sources_cli/test/cli_test.dart` |
| Zone member listing | `zoneMembers` | `apps/idr_target_cli/test/zone_members_test.dart` |

---

## 9. Tests executed (2026-10-26)

| Suite | Command | Result |
|---|---|---|
| Source identity | `applications/apps/sdks/idr_source`: `dart test test/source_identity_manager_test.dart test/bind_organization_test.dart` | **5 passed** |
| idrt CLI + zone members | `applications/apps/idr_target_cli`: `dart test test/zone_members_test.dart test/cli_test.dart` | **9 passed** |
| idr CLI | `applications/apps/idr_sources_cli`: `dart test test/cli_test.dart` | **8 passed** |
| Target zone/kickstart | `applications/apps/sdks/idr_target`: `dart test` **failed to load** (`dart:ui` / Flutter). `flutter test test/zone_authority_test.dart test/kickstart_test.dart` | **10 passed** |
| Billing session-policy + credential list | `Auth_repo/billing`: vitest those two files | **12 passed** (2 files) |
| `parseMachineHost` | `Auth_repo/better-auth`: `names.test.ts` | **3 passed** |
| Scenario A/B E2E | live `idrt`/`idr` + Ollama + Presence | **Not run** — no local billing/Presence/Ollama/org in this session |
| Presence `cargo test` fqhn | — | **Not run** |
| Full billing / enroll HTTP suites | — | **Not run** (subset only) |

`dart test` on `idr_target` is the wrong runner (Flutter package); use `flutter test`. That is an environment/tooling gap, not a product failure.

---

## 10. Gaps (requirements not implemented)

1. Named entity (brand/domain) as a **supported** setup option with uniqueness UX.
2. Entity/zone as Presence FQHNs (`acme.idr.to`, `fin.acme.idr.to`).
3. ~~Zone admin as a **signing** principal~~ Done 2026-10-27: the zone admin's machine makes its own zone key; the root signs it from Pending approvals (`zone_authority` enroll). Zone roles (admin/member) and settings (`membersApprove`, `adminsCreateSubzones`) live on billing (zone record metadata). See `docs/e2e-multi-user-cli.md` TC5.
4. ~~Source `--zone` / Path B inbox routing~~ Done 2026-10-27: `idr enroll --zone`; the request goes to that zone's admins (and the owner).
5. Post-approve **move** to a zone (Path A step 4).
6. Host uniqueness **per zone**; dotted `{label}.{zone}--{entity}` as the live `hostLabel`.
7. Domain/brand **ownership** verification for entity names.
8. Control-plane sync of local org graph (`syncFromControlPlane` throws not implemented).

---

## 11. Prioritized proposed fixes (do not start without approval)

1. **Docs/CLI honesty** — Describe live FQHN and “zone at approve only.” Tests: existing CLI/README; no new product behavior. *Low risk.*
2. **Named `entityId` on enterprise setup** (optional flag) — persist as `dpEntityId`; FQHNs `{host}--{name}.idr.to`. Tests: kickstart uniqueness, `assertEntityOwned`, `entityIdFromFqhn`. *Defer DNS proof.* Components: `ensureAdminCa`, kickstart, `idrt enterprise setup`.
3. **Zone in Source enroll metadata** (still signed on root box) — `enroll-create` `zone` hint for inbox filter. Tests: pending list filtered. *Does not yet move CA.*
4. **Live host = `{label}` at root, `{label}.{zonePath}--{entity}` in zone** + seat uniqueness on full host. Tests: two zones same `gpu-box`; duplicate in one zone rejected; Presence canonicalize dotted path; Source enroll matches. Components: `hosts.routes.ts` hostLabel regex, `registerHost`, `SourceIdentityManager`, seats.
5. **Zone-admin machine** — export/issue `zone_authority` to invited admin; `approve` authorized by zone SKI scope. Tests: cannot approve other zone; CSR signed by zone CA. Components: `invite`, `issue-delegate`, `EnrollmentManager.approve`.
6. **Path A assign-to-zone** — re-sign leaf with zone CA or explicit migrate. Tests: session-policy zone after move; old root-signed session behavior.
7. **E2E A/B** — scripted against local Billing + Presence + Ollama. Tests: this document’s scenarios A/B + negatives.

After each fix, the corresponding rows in §7 should move from Gap to Pass.

---

## 12. Org members in CLI

Implemented in-app: `idrt enterprise members` talks to Better Auth over the session cookie. Portal `/members` is unused by this command.

---

## 13. Live CLI validation (2026-10-26)

Run against local Billing (`127.0.0.1:3000`, org `acme`, owner session) with `dart run bin/idrt.dart` / `bin/idr.dart`. Presence (`:8081`) was **not running**, so `idr connect` / `idr active` / `idrt start` were not exercised.

| Workflow | Result |
|---|---|
| `enterprise org/members/zone list/devices/pending` | Pass (real data) |
| `members invite` (member) → listed under pending invitations | Pass |
| `members role/remove` on a **pending** invitee | Was a bare "not found"; now explains the invite is pending (`INVITE_PENDING`). Cancelling/changing a pending invite is not in the Dart billing SDK, so it still needs the portal. |
| `members role/remove` on an accepted member | Not run against real accounts (only real users were members). |
| `zone add legal`, `legal.emea`; bad label; missing parent | Pass |
| `zone invite`, `zone policy --allow ollama`, `zone show` | Pass (invite is a local label, as documented) |
| `idr enroll … --org acme --label qa-src-1` → pending → `approve --zone nosuch` (refused) → `approve --zone legal` → `idr enroll` approved | Pass |
| `enroll` bad FQHN | Exit was 3 (connect); now 64 (usage) |
| `enroll --org nosuchorg`; `reject` then re-enroll (`ENROLLMENT_REJECTED`) | Pass |
| `revoke <ski>` / `revoke <zone>` / unknown | Pass |

Open limitations:
- Billing lists a zone-approved Source with `zone: null` (zone is only stored for `zone_authority` rows), so `zone show` members and `devices` show it under root. The zone is inside the signed credential. Fix is in Billing.
- `pending` shows an empty requester for Source enrollments.
- Pending invitations cannot be cancelled from the CLI (SDK lacks it).
- On Windows, an argument with a space (`--name "Legal QA"`) fails through the Flutter `dart.bat` shim when the install path contains a space; unrelated to the CLI.
