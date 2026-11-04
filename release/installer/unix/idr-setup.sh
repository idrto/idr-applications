#!/bin/sh
# IDR Setup for Linux and macOS: pick components, get them plus the agents they
# need (shared ones once) from the signed release manifest, install into one
# folder, link idr / idrt into ~/.local/bin. Rerun to add, update or remove.
#
#   sh idr-setup.sh                                   # interactive
#   sh idr-setup.sh --components target-cli,source-cli
#   sh idr-setup.sh --uninstall
#   curl -fsSL https://billing.idr.to/staging/setup/idr-setup.sh | sh -s -- --components target-cli
#
# Options: --prefix DIR (default ~/.local/share/idr), --bin-dir DIR (default ~/.local/bin).
# Env: IDR_CHANNEL, IDR_RELEASE_BASE (default https://billing.idr.to).
# Sign-ins, keys and device identities live outside the install folder and are never touched.
set -eu

CHANNEL="${IDR_CHANNEL:-staging}"
BASE="${IDR_RELEASE_BASE:-https://billing.idr.to}"
URL="${BASE%/}/$CHANNEL/"
PREFIX="${HOME}/.local/share/idr"
BIN_DIR="${HOME}/.local/bin"
COMPONENTS=""
UNINSTALL=0
TAB="$(printf '\t')"

# Release signing key (public). Matches release/release-key.pem.
PUBKEY='-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA4Yy2x9ljBck0G+nvld2e
VCGLqJZwTvR9viywESRfY6jLkd3XpnyBEnvl6f9/1jQFrw4ZNpC9TRQpngpBFkbH
IizEJUfqtSu2DYknHwUc1G0F37plxKowgpCQGfxui4YJsiQgsaQAEA2lXxEUXtzn
8m84LwEyr9WqJvYMVFmiUDgKeOAOChpcs0R9r1gRiQyklWfCGO5Vwt3RtzjKD7qN
0nmsLqFpq+KWZuUMYRMFhux4HwHhvegvT0c4H9yvxbfFyZtIQ6sIAWUPsWr10DqG
US9m2mUgf/2rqkCXDCOtDE6xfcWOc4f0SjPYUKDe90hmaNC0/p5ca8fRbKyG8Vdy
wkvl2RtYp6GU3oA8EBk6gHQu9+Vk7JVbJW+81rXZb79D6A6sw+TikwZDvVhrwOo+
WRt/Po13UFMDUl9VCxr1TihVu+bB/nzWi0SYyuaEwnR80T2xaonxp/nMjvcO36ZT
dBbWx/zi8txSBeuJd6791FfT/aZ/zTGzI3E62xMcVbPDAgMBAAE=
-----END PUBLIC KEY-----'

die() { printf 'idr-setup: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --components) COMPONENTS="${2:-}"; shift ;;
    --components=*) COMPONENTS="${1#*=}" ;;
    --prefix) PREFIX="${2:-}"; shift ;;
    --prefix=*) PREFIX="${1#*=}" ;;
    --bin-dir) BIN_DIR="${2:-}"; shift ;;
    --bin-dir=*) BIN_DIR="${1#*=}" ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,13p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
STATE="$PREFIX/.idr"

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64|Linux/amd64) PLATFORM=linux-x64 ;;
  Darwin/arm64) PLATFORM=macos-arm64 ;;
  *) die "no IDR build for $(uname -s) $(uname -m) yet (available: Linux x64, macOS Apple silicon, Windows x64)." ;;
esac

for tool in curl tar openssl; do command -v "$tool" >/dev/null 2>&1 || die "needs $tool"; done
if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum "$1" | cut -d' ' -f1; }
else sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- Installed state ---------------------------------------------------------

installed_ids() { [ -d "$STATE" ] && for f in "$STATE"/*.sha256; do [ -f "$f" ] && basename "$f" .sha256; done; true; }
installed_sha() { cat "$STATE/$1.sha256" 2>/dev/null || true; }

# Delete files of a removed/updated component unless another component ships them.
remove_orphans() { # <file listing>
  [ -s "$1" ] || return 0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -d "$STATE" ] && cat "$STATE"/*.files 2>/dev/null | grep -qxF "$rel"; then continue; fi
    rm -f "$PREFIX/$rel"
    d="$(dirname "$PREFIX/$rel")"
    while [ "$d" != "$PREFIX" ] && rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
  done < "$1"
}

link_bins() {
  mkdir -p "$BIN_DIR"
  for pair in target-cli:idrt source-cli:idr; do
    id="${pair%%:*}"; exe="${pair#*:}"
    if [ -f "$STATE/$id.sha256" ] && [ -x "$PREFIX/$exe" ]; then
      ln -sf "$PREFIX/$exe" "$BIN_DIR/$exe"
    elif [ -L "$BIN_DIR/$exe" ] && [ "$(readlink "$BIN_DIR/$exe")" = "$PREFIX/$exe" ]; then
      rm -f "$BIN_DIR/$exe"
    fi
  done
}

if [ "$UNINSTALL" = 1 ]; then
  for id in $(installed_ids); do
    mv "$STATE/$id.files" "$TMP/$id.files" 2>/dev/null || true
    rm -f "$STATE/$id.sha256"
    remove_orphans "$TMP/$id.files"
  done
  rm -rf "$STATE"; rmdir "$PREFIX" 2>/dev/null || true
  link_bins
  say "IDR removed from $PREFIX. Your sign-ins and device identities were kept."
  exit 0
fi

# --- Signed manifest -----------------------------------------------------------

printf '%s\n' "$PUBKEY" > "$TMP/key.pem"
fetch_manifest() {
  curl -fsSL "${URL}manifest.tsv" -o "$TMP/manifest.tsv" &&
  curl -fsSL "${URL}manifest.tsv.sig" -o "$TMP/manifest.tsv.sig" &&
  openssl dgst -sha256 -verify "$TMP/key.pem" -signature "$TMP/manifest.tsv.sig" "$TMP/manifest.tsv" >/dev/null 2>&1
}
# Retried once: the manifest and its signature are replaced as two renames.
fetch_manifest || { sleep 3; fetch_manifest; } || die "could not download a validly signed manifest from ${URL}. Nothing was changed."
grep -qx "channel${TAB}$CHANNEL" "$TMP/manifest.tsv" || die "manifest is not for channel $CHANNEL."
VERSION="$(sed -n "s/^version${TAB}//p" "$TMP/manifest.tsv")"

field() { # <id> <column 4..9> for this platform
  awk -F '\t' -v id="$1" -v p="$PLATFORM" -v c="$2" '$1=="pkg" && $2==id && $3==p {print $c; exit}' "$TMP/manifest.tsv"
}
apps="$(awk -F '\t' -v p="$PLATFORM" '$1=="pkg" && $3==p && $8=="app" {print $2}' "$TMP/manifest.tsv")"
[ -n "$apps" ] || die "IDR $VERSION has no build for $PLATFORM. Nothing was changed."

# --- Choose components ---------------------------------------------------------

if [ -z "$COMPONENTS" ]; then
  (exec </dev/tty) 2>/dev/null || die "no terminal to ask in: pass --components (one or more of: $(echo $apps | tr ' ' ','))."
  say "IDR $VERSION ($CHANNEL) for $PLATFORM"
  say ""
  i=0
  for id in $apps; do
    i=$((i + 1))
    mark=" "; [ -n "$(installed_sha "$id")" ] && mark="installed"
    printf '  %d) %-16s %s\n' "$i" "$(field "$id" 9)" "$mark"
  done
  say ""
  say "Type the numbers to install, separated by spaces (e.g. 1 3)."
  say "Components you leave out are removed. Empty answer = keep what is installed."
  printf '> '
  read -r answer < /dev/tty || answer=""
  if [ -z "$answer" ]; then
    COMPONENTS="$(for id in $apps; do [ -n "$(installed_sha "$id")" ] && echo "$id"; done | paste -sd, -)"
    [ -n "$COMPONENTS" ] || die "nothing selected."
  else
    for n in $answer; do
      id="$(echo $apps | tr ' ' '\n' | sed -n "${n}p")"
      [ -n "$id" ] || die "no component number $n."
      COMPONENTS="$COMPONENTS,$id"
    done
  fi
fi

# Selected + required, each once.
want=""
todo="$(echo "$COMPONENTS" | tr ',' ' ')"
while [ -n "$todo" ]; do
  set -- $todo; id="$1"; shift; todo="$*"
  case " $want " in *" $id "*) continue ;; esac
  [ -n "$(field "$id" 4)" ] || die "$id is not available for $PLATFORM."
  want="$want $id"
  req="$(field "$id" 7)"
  [ "$req" = "-" ] || todo="$todo $(echo "$req" | tr ',' ' ')"
done

# --- Download and verify everything first ------------------------------------

get=""
for id in $want; do
  sha="$(field "$id" 5)"
  if [ "$(installed_sha "$id")" = "$sha" ]; then say "Up to date: $(field "$id" 9)"; continue; fi
  say "Downloading $(field "$id" 9)"
  curl -fL --progress-bar "${URL}$(field "$id" 4)" -o "$TMP/$id.tar.gz" || die "download of $id failed. Nothing was changed."
  [ "$(sha256 "$TMP/$id.tar.gz")" = "$sha" ] || die "checksum mismatch for $id. Nothing was changed."
  get="$get $id"
done

# --- Install -------------------------------------------------------------------

mkdir -p "$STATE"
for id in $get; do
  stage="$STATE/stage-$id"
  rm -rf "$stage"; mkdir -p "$stage"
  tar -xzf "$TMP/$id.tar.gz" -C "$stage"
  (cd "$stage" && find . -type f | sed 's|^\./||') > "$TMP/$id.new"
  while IFS= read -r rel; do
    mkdir -p "$(dirname "$PREFIX/$rel")"
    mv -f "$stage/$rel" "$PREFIX/$rel"   # rename: safe even while the old binary runs
  done < "$TMP/$id.new"
  rm -rf "$stage"
  [ -f "$STATE/$id.files" ] && grep -vxF -f "$TMP/$id.new" "$STATE/$id.files" > "$TMP/$id.gone" || : > "$TMP/$id.gone"
  cp "$TMP/$id.new" "$STATE/$id.files"
  field "$id" 5 > "$STATE/$id.sha256"
  remove_orphans "$TMP/$id.gone"
  say "Installed $(field "$id" 9)"
done

for id in $(installed_ids); do
  case " $want " in *" $id "*) continue ;; esac
  mv "$STATE/$id.files" "$TMP/$id.files" 2>/dev/null || : > "$TMP/$id.files"
  rm -f "$STATE/$id.sha256"
  remove_orphans "$TMP/$id.files"
  say "Removed $id"
done
echo "$VERSION" > "$STATE/version"
link_bins

say ""
say "IDR $VERSION is installed in $PREFIX."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "Add $BIN_DIR to your PATH to run idr / idrt, e.g.: echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.profile" ;;
esac
if [ -n "$get" ] && command -v pgrep >/dev/null 2>&1 && pgrep -f "$PREFIX/target-agent" >/dev/null 2>&1; then
  say "A target-agent from the old version is still running: restart it (idrt stop, then idrt start)."
fi
