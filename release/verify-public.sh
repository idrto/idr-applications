#!/usr/bin/env bash
# After a publish: check what users actually get from the public URLs.
#   verify-public.sh https://billing.idr.to staging <local out dir with manifest.json + release-key.pem>
set -euo pipefail
base="${1%/}"; channel="$2"; out="$3"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "::error::$*"; exit 1; }

curl -fsS "$base/$channel/manifest.json" -o "$tmp/manifest.json" || fail "manifest not served at $base/$channel/manifest.json (Caddy routes deployed? see release/README.md)"
curl -fsS "$base/$channel/manifest.json.sig" -o "$tmp/manifest.json.sig"
cmp -s "$tmp/manifest.json" "$out/manifest.json" || fail "public manifest differs from the one just published"
openssl dgst -sha256 -verify "$out/release-key.pem" -signature "$tmp/manifest.json.sig" "$tmp/manifest.json" >/dev/null || fail "public manifest signature invalid"

# Every package, standalone download and setup file: served, right size, right hash for the small ones.
python3 - "$out/manifest.json" > "$tmp/files.tsv" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
seen = set()
for group in (m['components'], m['standalone']):
    for c in group:
        for f in c['files'].values():
            seen.add((f['path'], f['size'], f['sha256']))
for plats in m['setup'].values():
    for f in plats.values():
        seen.add((f['path'], f['size'], f['sha256']))
for p, size, sha in sorted(seen):
    print(f'{p}\t{size}\t{sha}')
PY
n=0
while IFS=$'\t' read -r path size sha; do
  got="$(curl -fsS -o "$tmp/f" -w '%{size_download}' "$base/$channel/$path")" || fail "not served: $path"
  [[ "$got" == "$size" ]] || fail "$path: $got bytes, expected $size"
  [[ "$(sha256sum "$tmp/f" | cut -d' ' -f1)" == "$sha" ]] || fail "$path: checksum mismatch"
  n=$((n + 1))
done < "$tmp/files.tsv"
echo "ok: $n files served with matching size and SHA-256"

for f in IDR-Setup.exe idr-setup.sh; do
  curl -fsSI "$base/$channel/setup/$f" >/dev/null || fail "setup/$f not served"
done
curl -fsS "$base/api/auth/jwks" >/dev/null || fail "billing API check failed after publish"
curl -fsS "$base/" | grep -qi '<html' || fail "billing portal check failed after publish"
echo "ok: setup files, billing API and portal respond"
