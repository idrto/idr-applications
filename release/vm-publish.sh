#!/usr/bin/env bash
# Runs on the VM (uploaded by CI next to the bundle). Only writes under $ROOT.
#
#   vm-publish.sh publish <channel> <version> <bundle.tgz>
#       bundle: packages/<version>/… (with SHA256SUMS), manifest.{json,tsv}{,.sig},
#       release-key.pem
#   vm-publish.sh promote <version> <bundle.tgz>
#       bundle: the stable manifest.{json,tsv}{,.sig} and release-key.pem;
#       copies staging/packages/<version> to stable/ first.
#
# Order makes a failed run harmless: verify everything, move the version folder
# into place (write-once), then swap the manifest last. Caddy serves $ROOT
# read-only. The download website is deployed separately (Auth_repo/deploy/deploy-download.sh).
set -euo pipefail
umask 022

ROOT="${IDR_DOWNLOADS_ROOT:-/opt/idr-downloads}"
KEEP_STAGING=15   # staging versions kept on disk; stable versions are never pruned
cmd="${1:?usage: vm-publish.sh publish|promote …}"

exec 9>"$ROOT/.publish.lock"
flock -w 600 9 || { echo "ABORT: another publish holds $ROOT/.publish.lock" >&2; exit 1; }

work="$(mktemp -d "$ROOT/.incoming/work.XXXXXX")"
trap 'rm -rf "$work"' EXIT

unpack() { # <bundle>: needs ~3x its size free so the billing services never run out of disk
  local need=$(( $(stat -c %s "$1") * 3 / 1024 + 1048576 ))
  local free; free=$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')
  (( free > need )) || { echo "ABORT: only $((free / 1024)) MB free under $ROOT" >&2; exit 1; }
  tar -xzf "$1" -C "$work"
}

verify_manifests() { # <dir> <channel> <version>; CI already verified the signature, this re-checks it here
  command -v openssl >/dev/null || echo "warning: no openssl on this host, signature not re-checked" >&2
  command -v openssl >/dev/null && for f in manifest.json manifest.tsv; do
    openssl dgst -sha256 -verify "$work/release-key.pem" -signature "$1/$f.sig" "$1/$f" >/dev/null \
      || { echo "ABORT: bad signature on $f" >&2; exit 1; }
  done
  grep -qx "channel	$2" "$1/manifest.tsv" && grep -qx "version	$3" "$1/manifest.tsv" \
    || { echo "ABORT: manifest is not $2 $3" >&2; exit 1; }
}

verify_packages() { # <channel root> <version>: every manifest entry exists with its hash
  local root="$1" v="$2"
  (cd "$root/packages/$v" && sha256sum --check --strict --quiet SHA256SUMS)
  local listed actual
  listed=$(wc -l < "$root/packages/$v/SHA256SUMS")
  actual=$(find "$root/packages/$v" -type f ! -name SHA256SUMS ! -name 'manifest.*' | wc -l)
  (( listed == actual )) || { echo "ABORT: $actual files on disk, $listed in SHA256SUMS" >&2; exit 1; }
  awk -F '\t' '$1=="pkg" {print $5 "  " $4}' "$work/manifest.tsv" | (cd "$root" && sha256sum --check --strict --quiet)
}

publish_manifests() { # <channel root> <version>: history copy, then the live swap
  local root="$1" v="$2"
  for f in manifest.json manifest.json.sig manifest.tsv manifest.tsv.sig; do
    cp "$work/$f" "$root/packages/$v/$f"
  done
  for f in manifest.json manifest.tsv; do
    cp "$work/$f.sig" "$root/.$f.sig.tmp"; cp "$work/$f" "$root/.$f.tmp"
    mv -f "$root/.$f.sig.tmp" "$root/$f.sig"; mv -f "$root/.$f.tmp" "$root/$f"
  done
}

copy_setup() { # <channel root> <version> <channel>: stable URLs /<channel>/setup/<file>
  mkdir -p "$1/setup"
  for f in "$1/packages/$2/setup/$3"/*; do
    cp "$f" "$1/setup/.$(basename "$f").tmp" && mv -f "$1/setup/.$(basename "$f").tmp" "$1/setup/$(basename "$f")"
  done
}

case "$cmd" in
publish)
  channel="${2:?channel}"; v="${3:?version}"; bundle="${4:?bundle}"
  [[ "$channel" =~ ^(staging|stable)$ && "$v" =~ ^[0-9A-Za-z.+-]+$ ]] || { echo "ABORT: bad channel/version" >&2; exit 1; }
  dest="$ROOT/$channel/packages/$v"
  [[ ! -e "$dest" ]] || { echo "ABORT: $channel $v is already published; versions are write-once" >&2; exit 1; }
  unpack "$bundle"
  verify_manifests "$work" "$channel" "$v"
  mkdir -p "$ROOT/$channel/packages"
  mv "$work/packages/$v" "$dest"
  verify_packages "$ROOT/$channel" "$v" || { rm -rf "$dest"; echo "ABORT: verification failed; $v removed" >&2; exit 1; }
  copy_setup "$ROOT/$channel" "$v" "$channel"
  publish_manifests "$ROOT/$channel" "$v"

  if [[ "$channel" == staging ]]; then
    # `|| true` on grep: with nothing to prune it gets no input, exits 1, and
    # pipefail would end the script with status 1 after a successful publish.
    ls -1dt "$ROOT"/staging/packages/*/ | tail -n +$((KEEP_STAGING + 1)) | { grep -v "/$v/\$" || true; } | xargs -r rm -rf
  fi
  echo "published $channel $v"
  ;;
promote)
  v="${2:?version}"; bundle="${3:?bundle}"
  src="$ROOT/staging/packages/$v" dest="$ROOT/stable/packages/$v"
  [[ -d "$src" ]] || { echo "ABORT: staging $v does not exist" >&2; exit 1; }
  [[ ! -e "$dest" ]] || { echo "ABORT: stable $v already exists" >&2; exit 1; }
  unpack "$bundle"
  verify_manifests "$work" stable "$v"
  mkdir -p "$ROOT/stable/packages"
  cp -a "$src" "$ROOT/stable/packages/.$v.tmp"
  rm -f "$ROOT/stable/packages/.$v.tmp"/manifest.*
  mv "$ROOT/stable/packages/.$v.tmp" "$dest"
  verify_packages "$ROOT/stable" "$v" || { rm -rf "$dest"; echo "ABORT: verification failed" >&2; exit 1; }
  copy_setup "$ROOT/stable" "$v" stable
  publish_manifests "$ROOT/stable" "$v"
  echo "promoted $v to stable"
  ;;
*) echo "unknown command $cmd" >&2; exit 2 ;;
esac
