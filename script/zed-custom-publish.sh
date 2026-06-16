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

# Phase selector so a slow release build and the /Applications swap can run as
# two separate invocations: an agent can build in the background, then prompt
# before copying.
#   build   - run the slow build + bundle, record the bundle path, then STOP.
#             Leaves /Applications untouched and never blocks.
#   install - copy the bundle a prior `build` produced into /Applications.
#             Never invokes cargo, so no rebuild when code is unchanged.
#   all     - build then install in one shot (default; `mise run publish`).
MODE="${ZED_CUSTOM_MODE:-all}"
case "$MODE" in
  build|install|all) ;;
  *) echo "ZED_CUSTOM_MODE must be build|install|all (got: $MODE)" >&2; exit 1 ;;
esac

# Zed's cargo-bundle fork unwraps a term-crate color call; under TERM=dumb (e.g.
# an agent/CI shell with no color capability) that panics with
# Error(Term(ColorOutOfRange)). Force a 256-color TERM so the bundle step never
# depends on the caller's terminal.
if [ "${TERM:-dumb}" = dumb ]; then
  export TERM=xterm-256color
fi

# Back-compat: ZED_CUSTOM_DEFER_INSTALL=1 used to mean "build, then wait for the
# live app to quit before installing". Still honored for MODE=all.
DEFER_INSTALL="${ZED_CUSTOM_DEFER_INSTALL:-0}"

# Desktop notification (best-effort; no-op when no GUI session is reachable).
notify() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true; }

# True while the installed Zed Custom is running. Matches this bundle's binary
# path specifically so it never confuses the cargo-run dev instance or the
# official Zed. We WAIT for the user to quit; we never kill it (a forced kill
# can wedge relaunch and lose unsaved state).
app_running() { pgrep -f "${DST}/Contents/MacOS/" >/dev/null 2>&1; }

GIT_VERSION="v2.43.3"
GIT_VERSION_SHA="fa29823"

export ZED_BUNDLE=true
export CXXFLAGS="-stdlib=libc++"
channel="$(cat crates/zed/RELEASE_CHANNEL)"
export ZED_RELEASE_CHANNEL="$channel"

triple="$(rustc -vV | awk '/^host:/{print $2}')"

# Where MODE=build records the freshly built bundle for MODE=install to read.
# Under target/ (gitignored) so it never leaks into the repo.
BUNDLE_MARKER="target/${triple}/release/.zed-custom-app-path"

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

if [ "$MODE" = install ]; then
  # Copy phase only: reuse the bundle MODE=build produced. Never runs cargo.
  [ -f "$BUNDLE_MARKER" ] \
    || { echo "no prior build found ($BUNDLE_MARKER) — run 'mise run build:prod' first" >&2; exit 1; }
  app_path="$(cat "$BUNDLE_MARKER")"
  [ -n "$app_path" ] && [ -d "$app_path" ] \
    || { echo "recorded bundle missing (got: '$app_path') — rebuild with 'mise run build:prod'" >&2; exit 1; }
  echo "Installing previously built bundle: $app_path"
else
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

  # Record the bundle so a later MODE=install can copy it without rebuilding.
  printf '%s\n' "$app_path" > "$BUNDLE_MARKER"

  # build-only phase stops here, leaving the live app and /Applications alone.
  if [ "$MODE" = build ]; then
    notify "$APP_NAME build ready" "Quit $APP_NAME, then run: mise run publish:install"
    echo "Build complete. Bundle ready: $app_path"
    echo "Install it (after quitting ${APP_NAME}) with: mise run publish:install"
    exit 0
  fi
fi

# Slow build is done. In deferred mode, hold here until the live app is closed
# so the swap + re-sign never hits a running bundle.
if { [ "$MODE" = install ] || [ "$DEFER_INSTALL" = "1" ]; } && app_running; then
  notify "$APP_NAME build ready" "Quit $APP_NAME to install the new build."
  echo "Build complete. Waiting for ${APP_NAME} to quit before replacing ${DST}…"
  while app_running; do sleep 2; done
  echo "${APP_NAME} closed; installing."
fi

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
# No -v: a self-signed dev cert is untrusted (CSSMERR_TP_NOT_TRUSTED) and so is
# excluded from the "valid" list, but codesign still signs with it. Only require
# that the identity (cert + private key) exists.
if ! security find-identity -p codesigning 2>/dev/null | grep -qF "$CERT"; then
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

notify "$APP_NAME installed" "Launch with: open -a $APP_NAME"
echo "Installed: $DST"
echo "Launch natively:  open -a \"${APP_NAME}\""
