# App releases

Every push to `main` builds the apps (CI workflow), packages them, signs a release
manifest, attaches everything to a GitHub prerelease (`staging-<version>`) and
publishes it to the billing VM. The download website at
**https://billing.idr.to/staging/download/** reads that manifest; the website itself
lives in `Auth_repo/download-site` and deploys separately
(`Auth_repo/deploy/deploy-download.sh`), so app releases never touch it and site
updates never rebuild the apps.

```
build / target-app / setup-windows jobs ──▶ publish job (ubuntu)
  idr, idrt, Target GUI, IDR-Setup.exe        package.py → packages + manifest.{json,tsv}
  (also kept as Actions artifacts)            openssl sign (IDR_RELEASE_SIGNING_KEY)
                                              gh release create staging-<version>
                                              scp + vm-publish.sh (SERVER_1_*) ──▶ VM /opt/idr-downloads
                                              verify-public.sh (downloads every file back)
```

## Components

The apps find their native pieces next to their own executable, so the installers
put every component in one folder and a shared dependency is installed once.

| Component | Platforms | Requires | Contents |
|---|---|---|---|
| `target-gui` | windows-x64 | `target-agent` | Target GUI (Flutter bundle) |
| `target-cli` | windows-x64, linux-x64, macos-arm64 | `target-agent` | `idrt`, `config/prod.json` |
| `source-cli` | windows-x64, linux-x64, macos-arm64 | none | `idr`, `idr_c_api`, `source-agent`, `config/prod.json` |
| `target-agent` | all three | none | `target-agent` |

macOS builds are opt-in: set the repository variable `BUILD_MACOS` to `true`
(Settings → Secrets and variables → Actions → Variables) once the organization has
macOS runner minutes. Without it the release has Windows and Linux only, and the
website shows macOS as not available yet. There is no Source GUI yet; the website shows it as not available. Standalone
downloads (`packages/<v>/standalone/`) are the same apps with the agent inside, for
people who don't use Setup.

## Installers

| OS | File | What it is |
|---|---|---|
| Windows | `IDR-Setup.exe` | Inno Setup wizard ([idr-setup.iss](installer/windows/idr-setup.iss)): component page, download page with SHA-256 checks, per-user install in `%LOCALAPPDATA%\Programs\IDR` (no admin), Start menu / desktop shortcut for the GUI, user `PATH`, uninstaller. The work is done by [idr-install.ps1](installer/windows/idr-install.ps1), which also runs alone (`-Mode Install -Components target-cli`). |
| Linux, macOS | `idr-setup.sh` | POSIX `sh` script ([idr-setup.sh](installer/unix/idr-setup.sh)): numbered menu or `--components`, installs to `~/.local/share/idr`, links `idr`/`idrt` into `~/.local/bin`, `--uninstall`. Needs `curl`, `tar`, `openssl`. |

Both fetch the channel's manifest, check its RSA signature against the public key
built into them ([release-key.pem](release-key.pem)), add the required dependencies,
skip components already installed at the same hash, verify every download before
changing anything, and remove components that were deselected (files another
component still ships are kept). Rerunning adds, updates or removes. Sign-ins, keys
and device identities live in `%APPDATA%` / the home folder and are never touched.

## VM layout

```
/opt/idr-downloads/                 mounted read-only into the portal (Caddy) as /downloads
├── staging/
│   ├── manifest.json(.sig)         live manifest, replaced last
│   ├── manifest.tsv(.sig)          same data for idr-setup.sh
│   ├── setup/IDR-Setup.exe, idr-setup.sh
│   └── packages/<version>/         write-once; last 15 staging versions kept
│       ├── <component>-<platform>.zip|.tar.gz
│       ├── standalone/…  setup/{staging,stable}/…  SHA256SUMS  manifest.*
├── stable/                         same shape, filled only by the Promote workflow
└── .incoming/                      uploads in progress (not served)
```

`vm-publish.sh` refuses an existing version, checks free disk space, the manifest
signature, `SHA256SUMS` and every manifest entry, then moves the version folder in,
then swaps the manifest (signature first, then data, each with one rename). A failed
or cancelled run leaves the live manifest as it was.

## Caddy routes (Auth_repo/deploy/Caddyfile)

| Path | Served by |
|---|---|
| `/api/*`, `/link*`, `/oauth/*`, `/portal/*`, `/.well-known/*` | billing API (unchanged) |
| `/staging/download` | 308 to `/staging/download/` |
| `/staging/download/*` | `idr-download` website container (Auth_repo/download-site) |
| `/(staging\|stable)/manifest.*`, `…/packages/*`, `…/setup/*` | Caddy `file_server` from `/downloads`; packages cached as immutable |
| everything else | billing portal SPA (unchanged) |

## One-time setup

1. **Signing key secret:** add the private key as the repository secret
   `IDR_RELEASE_SIGNING_KEY` (PEM, the whole file). Its public half is
   `release-key.pem`, also built into both installers. To rotate: generate a new pair
   (`openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072`), replace
   `release-key.pem`, the `$PublicKeyXml` in `idr-install.ps1` and `PUBKEY` in
   `idr-setup.sh`, then update the secret.
2. **Proxy:** redeploy the billing stack once with `bash Auth_repo/deploy/deploy.sh`.
   It ships the Caddyfile routes, mounts `/opt/idr-downloads` read-only into the portal
   and joins the portal to the `idr-download` network. Then deploy the website with
   `bash Auth_repo/deploy/deploy-download.sh`.
3. **SSH:** CI logs in with `SERVER_1_HOST` / `SERVER_1_USER` / `SERVER_1_PASSWORD`
   (sshpass, password via env) and checks the VM's host key against
   [known_hosts](known_hosts). If the VM is rebuilt, re-scan
   (`ssh-keyscan <ip>`, rename the host to `idr-vm`) and review the change.
   The user needs write access to `/opt/idr-downloads` only.

## Promote to stable

Actions → **Promote to stable** → enter a staging version (see
`/staging/manifest.json`). It copies `staging/packages/<v>` to `stable/`, re-signs the
manifest with `channel: stable` and publishes it at `/stable/manifest.json`. The
stable Setup files (`/stable/setup/…`) read the stable channel.

## Versions

`VERSION` (here `0.2.0`) plus the CI run number: `0.2.0-57`. Bump `VERSION` for a
new release line.
