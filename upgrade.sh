#!/usr/bin/env bash
# Upgrade the Claude Desktop flatpak to the latest official release.
#
#   1. Query Anthropic's apt repo for the newest amd64 .deb
#   2. Download it and verify its SHA256
#   3. Generate claude-desktop_<ver>_amd64/ from ./template
#   4. flatpak-builder -> repo -> single-file bundle
#   5. Install the bundle (user installation)
#
# Usage: ./upgrade.sh [options]
#   -c, --check          only report installed / latest version, then exit
#   -f, --force          rebuild even if that version is already installed
#   -v, --version VER    use a specific version instead of the latest
#   -n, --no-install     build the bundle but do not install it
#   -C, --clean-old      delete older claude-desktop_* folders after a successful build
#   -h, --help
set -euo pipefail

APP_ID="com.anthropic.Claude"
ARCH="x86_64"
APT_BASE="https://downloads.claude.ai/claude-desktop/apt/stable"
PACKAGES_URL="$APT_BASE/dists/stable/main/binary-amd64/Packages"
INRELEASE_URL="$APT_BASE/dists/stable/InRelease"
RUNTIME_BRANCH="26.08"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$ROOT/template"

CHECK=0 FORCE=0 INSTALL=1 CLEAN=0 WANT_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--check) CHECK=1 ;;
    -f|--force) FORCE=1 ;;
    -v|--version) WANT_VERSION="${2:?--version needs a value}"; shift ;;
    -n|--no-install) INSTALL=0 ;;
    -C|--clean-old) CLEAN=1 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# Inside a Flatpak'd shell (e.g. Claude Code) flatpak/git live on the host.
if command -v flatpak >/dev/null 2>&1; then
  HOST=()
elif command -v flatpak-spawn >/dev/null 2>&1; then
  HOST=(flatpak-spawn --host)
else
  die "flatpak not found (and no flatpak-spawn to reach the host)"
fi
"${HOST[@]}" flatpak-builder --version >/dev/null 2>&1 \
  || die "flatpak-builder is not installed"
command -v curl >/dev/null || die "curl is required"

# ---- 1. find the target version -------------------------------------------
log "Querying $APT_BASE"
packages="$(curl -fsSL "$PACKAGES_URL")"

# Print "version<TAB>filename<TAB>size<TAB>sha256" for each claude-desktop stanza.
list_versions() {
  awk 'BEGIN{RS="";FS="\n"}
    { v="";f="";s="";h="";p=0
      for(i=1;i<=NF;i++){
        if($i=="Package: claude-desktop")p=1
        else if($i ~ /^Version: /)v=substr($i,10)
        else if($i ~ /^Filename: /)f=substr($i,11)
        else if($i ~ /^Size: /)s=substr($i,7)
        else if($i ~ /^SHA256: /)h=substr($i,9)
      }
      if(p)print v"\t"f"\t"s"\t"h }' <<<"$packages"
}

if [[ -n "$WANT_VERSION" ]]; then
  entry="$(list_versions | awk -F'\t' -v v="$WANT_VERSION" '$1==v' | head -1)"
  [[ -n "$entry" ]] || die "version $WANT_VERSION not in the apt repo"
else
  entry="$(list_versions | sort -t$'\t' -k1,1V | tail -1)"
  [[ -n "$entry" ]] || die "no claude-desktop package found in the apt repo"
fi
IFS=$'\t' read -r VERSION FILENAME SIZE SHA256 <<<"$entry"

installed="$("${HOST[@]}" flatpak info --user "$APP_ID" 2>/dev/null | awk -F': *' '/^ *Version:/{print $2}' || true)"
[[ -n "$installed" ]] || installed="$("${HOST[@]}" flatpak info "$APP_ID" 2>/dev/null | awk -F': *' '/^ *Version:/{print $2}' || true)"
last_built="$(ls -d "$ROOT"/claude-desktop_*_amd64 2>/dev/null | sed -E 's/.*claude-desktop_(.*)_amd64/\1/' | sort -V | tail -1 || true)"

echo "latest available : $VERSION"
echo "installed        : ${installed:-<none>}"
echo "last built here  : ${last_built:-<none>}"
(( CHECK )) && exit 0

if [[ "$installed" == "$VERSION" && $FORCE -eq 0 ]]; then
  echo "Already up to date. Use --force to rebuild."
  exit 0
fi

# ---- 2. download + verify -------------------------------------------------
WORK="$ROOT/claude-desktop_${VERSION}_amd64"
DEB="$WORK/claude-desktop_${VERSION}_amd64.deb"
mkdir -p "$WORK"

sha_ok() { [[ -f "$DEB" ]] && [[ "$(sha256sum "$DEB" | cut -d' ' -f1)" == "$SHA256" ]]; }

if sha_ok; then
  log "Using already-downloaded $(basename "$DEB")"
else
  log "Downloading $(basename "$DEB") ($((SIZE / 1024 / 1024)) MiB)"
  curl -fL --retry 3 -C - -o "$DEB" "$APT_BASE/$FILENAME"
  sha_ok || { rm -f "$DEB"; die "SHA256 mismatch for downloaded .deb"; }
fi
echo "sha256 OK: $SHA256"

# ---- 3. generate the build dir from templates -----------------------------
log "Generating build files in $(basename "$WORK")"
DATE="$(date -u +%F)"
cp "$TEMPLATE/claude-desktop.sh" "$WORK/claude-desktop.sh"
chmod 755 "$WORK/claude-desktop.sh"
sed -e "s#@VERSION@#$VERSION#g" -e "s#@DATE@#$DATE#g" \
  "$TEMPLATE/com.anthropic.Claude.metainfo.xml" > "$WORK/com.anthropic.Claude.metainfo.xml"
sed -e "s#@DEB@#$(basename "$DEB")#g" \
  "$TEMPLATE/com.anthropic.Claude.yml" > "$WORK/com.anthropic.Claude.yml"

# Sanity check: the layout our manifest relies on still exists in the .deb.
log "Checking .deb layout"
listing="$(dpkg-deb -c "$DEB" 2>/dev/null || bsdtar -xOf "$DEB" data.tar.xz 2>/dev/null | bsdtar -tf - 2>/dev/null || true)"
if [[ -n "$listing" ]]; then
  for p in usr/lib/claude-desktop/claude-desktop \
           usr/share/applications/com.anthropic.Claude.desktop \
           usr/share/icons/hicolor/256x256/apps/claude-desktop.png; do
    grep -q "$p" <<<"$listing" || die "expected '$p' missing from the .deb; the manifest needs updating"
  done
  echo "layout OK"
else
  echo "(no dpkg-deb/bsdtar here; layout check skipped, flatpak-builder will fail loudly if it changed)"
fi

# ---- 4. build -------------------------------------------------------------
log "Preparing Flathub runtimes"
"${HOST[@]}" flatpak remote-add --if-not-exists --user flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
"${HOST[@]}" flatpak install --user --arch="$ARCH" --assumeyes flathub \
  "org.freedesktop.Platform//$RUNTIME_BRANCH" \
  "org.freedesktop.Sdk//$RUNTIME_BRANCH" \
  "org.electronjs.Electron2.BaseApp//$RUNTIME_BRANCH"

log "Building flatpak"
cd "$WORK"
"${HOST[@]}" flatpak-builder --force-clean --arch="$ARCH" \
  --repo="$WORK/repo" "$WORK/build-dir" "$WORK/$APP_ID.yml"
"${HOST[@]}" flatpak build-bundle --arch="$ARCH" "$WORK/repo" "$WORK/$APP_ID.flatpak" "$APP_ID"
echo "Bundle: $WORK/$APP_ID.flatpak"

# ---- 5. install -----------------------------------------------------------
if (( INSTALL )); then
  log "Installing"
  "${HOST[@]}" flatpak install --user --reinstall --assumeyes "$WORK/$APP_ID.flatpak" \
    || "${HOST[@]}" flatpak install --user --assumeyes "$WORK/$APP_ID.flatpak"
  echo "Installed $VERSION. Run with: flatpak run $APP_ID"
else
  echo "Skipped install. Install with: flatpak install --user $WORK/$APP_ID.flatpak"
fi

# ---- 6. clean up older builds --------------------------------------------
if (( CLEAN )); then
  for old in "$ROOT"/claude-desktop_*_amd64; do
    [[ "$old" == "$WORK" ]] && continue
    [[ -d "$old" ]] || continue
    log "Removing old build $(basename "$old")"
    rm -rf "$old"
  done
  rm -f "$ROOT"/claude-desktop_*_amd64.deb
fi
log "Done: Claude Desktop $VERSION"
