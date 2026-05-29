#!/usr/bin/env bash
# CUSTOM (fork): build a release "Zed Custom" .app, stable self-sign it, and
# install to /Applications for native launch with TCC grants that survive
# rebuilds. Replicates the essential parts of script/bundle-mac (build +
# cargo-bundle + git/cli helpers) but skips DMG creation, the global npm install,
# and notarization. macOS only.
#
# Signing uses a stable self-signed cert (see `mise run cert:create`) so the
# designated requirement pins to the cert leaf, not the cdhash — TCC grants then
# persist across rebuilds. (Ad-hoc signing re-prompts every build.)
set -euo pipefail

[ "$(uname -s)" = "Darwin" ] || { echo "zed-custom-publish is macOS-only"; exit 0; }

CERT="${ZED_CUSTOM_CERT:-Zed Custom Dev}"
APP_NAME="${ZED_CUSTOM_APP_NAME:-ZedCustom}"
BUNDLE_ID="${ZED_CUSTOM_BUNDLE_ID:-dev.zed.zed-custom}"
DST="/Applications/${APP_NAME}.app"

GIT_VERSION="v2.43.3"
GIT_VERSION_SHA="fa29823"

export ZED_BUNDLE=true
export CXXFLAGS="-stdlib=libc++"
channel="$(cat crates/zed/RELEASE_CHANNEL)"
export ZED_RELEASE_CHANNEL="$channel"

triple="$(rustc -vV | awk '/^host:/{print $2}')"

download_git() {
  local arch="$1" target="$2" tmp url
  tmp="$(mktemp -d)"
  case "$arch" in
    aarch64-apple-darwin) url="https://github.com/desktop/dugite-native/releases/download/${GIT_VERSION}/dugite-native-${GIT_VERSION}-${GIT_VERSION_SHA}-macOS-arm64.tar.gz" ;;
    x86_64-apple-darwin)  url="https://github.com/desktop/dugite-native/releases/download/${GIT_VERSION}/dugite-native-${GIT_VERSION}-${GIT_VERSION_SHA}-macOS-x64.tar.gz" ;;
    *) echo "unsupported arch: $arch" >&2; rm -rf "$tmp"; return 1 ;;
  esac
  curl --silent --fail --location "$url" | tar -xz -C "$tmp" -f - bin/git
  mv "$tmp/bin/git" "$target"
  rm -rf "$tmp"
}

# Ensure Zed's cargo-bundle fork is present.
if [ "$(cargo -q bundle --help 2>&1 | head -n1 || true)" != "cargo-bundle v0.6.1-zed" ]; then
  echo "Installing zed cargo-bundle fork…"
  cargo install cargo-bundle --git https://github.com/zed-industries/cargo-bundle.git --branch zed-deploy
fi

echo "Building release binaries (this is the slow part)…"
cargo build --release --package zed --package cli --target "$triple"

# Promote the channel's bundle metadata to [package.metadata.bundle] so
# cargo-bundle picks it up, build the bundle, then restore Cargo.toml.
app_path=""
(
  cd crates/zed
  cp Cargo.toml Cargo.toml.publishbak
  trap 'cp Cargo.toml.publishbak Cargo.toml; rm -f Cargo.toml.publishbak' EXIT
  sd "package\\.metadata\\.bundle-${channel}" "package.metadata.bundle" Cargo.toml
  cargo bundle --release --target "$triple" --select-workspace-root | xargs >/tmp/zed-custom-app-path
)
app_path="$(cat /tmp/zed-custom-app-path)"
rm -f /tmp/zed-custom-app-path
[ -n "$app_path" ] && [ -d "$app_path" ] || { echo "bundle not found (got: '$app_path')" >&2; exit 1; }
echo "Built bundle: $app_path"

# Add the cli helper (the `zed` shell command) and the bundled git (git panel).
cp "target/${triple}/release/cli" "${app_path}/Contents/MacOS/cli"
download_git "$triple" "${app_path}/Contents/MacOS/git" \
  || echo "WARN: bundled git download failed; Zed will fall back to system git." >&2

# Deploy to a fixed path (stable path + bundle id + cert = stable TCC identity).
echo "Installing to ${DST}…"
ditto "$app_path" "$DST"

# Brand as a distinct app so it coexists with the official Zed. Keep the bundle
# id CONSTANT (TCC keys on it) — never derive it from a git hash or branch.
plist="${DST}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "$plist"

# Stable self-signed signature (no hardened runtime — self-signed can't). This
# overrides cargo-bundle's ad-hoc signature.
if ! security find-identity -p codesigning -v 2>/dev/null | grep -qF "$CERT"; then
  echo "Signing identity '$CERT' not found. Run: mise run cert:create" >&2
  exit 1
fi
codesign --force --deep --sign "$CERT" --timestamp=none "$DST"
xattr -cr "$DST" 2>/dev/null || true

# Refresh LaunchServices so the renamed app is registered.
LSR="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSR" -f "$DST" || true

dr="$(codesign -d -r- "$DST" 2>&1 | grep designated || echo 'no DR')"
echo "Designated requirement: $dr"
case "$dr" in
  *'cdhash H"'*) echo "WARN: DR is cdhash-pinned; TCC grants will reset on rebuild." >&2 ;;
esac

echo "Installed: $DST"
echo "Launch natively:  open -a \"${APP_NAME}\""
