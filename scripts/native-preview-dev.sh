#!/usr/bin/env bash
# Build, install, and launch the current native Kaisola source as one canonical
# preview app. Raw Xcode products live in a .noindex DerivedData folder so
# Spotlight no longer presents every intermediate build as another app.
#
#   ./scripts/native-preview-dev.sh
#   ./scripts/native-preview-dev.sh --launch-only
#   ./scripts/native-preview-dev.sh --clean-legacy
#
# The preview uses the native-only "Kaisola Native" broker by default, preserving
# its durable PTYs while remaining separate from the Electron daily driver. Set
# KAISOLA_NATIVE_BROKER_PROFILE=development for a clean-room Dev broker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT="$ROOT/native/KaisolaMac/KaisolaMac.xcodeproj"
SCHEME="KaisolaMacPreview"
CONFIGURATION="${KAISOLA_NATIVE_CONFIGURATION:-Debug}"
DERIVED_DATA="${KAISOLA_NATIVE_DERIVED_DATA:-$ROOT/.build/KaisolaNativePreview.noindex}"
APP="${KAISOLA_NATIVE_APP:-$HOME/Applications/Kaisola Preview.app}"
SOURCE_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/KaisolaMacPreview.app"
PROFILE_ROUTE="${KAISOLA_NATIVE_BROKER_PROFILE:-native}"
case "$PROFILE_ROUTE" in
  native) PROFILE_NAME="Kaisola Native" ;;
  development) PROFILE_NAME="Kaisola Dev" ;;
  *)
    /bin/echo "KAISOLA_NATIVE_BROKER_PROFILE must be native or development." >&2
    exit 2
    ;;
esac
BROKER_INFO="$HOME/Library/Application Support/$PROFILE_NAME/session-broker/broker.json"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
BUILD_CURRENT=1
CLEAN_LEGACY=0

# Installation replaces this exact bundle on every iteration. Keep that
# destructive boundary narrow even if an environment override is mistyped.
case "$APP" in
  "$HOME/Applications/"*.app) ;;
  *)
    /bin/echo "KAISOLA_NATIVE_APP must be an app inside $HOME/Applications: $APP" >&2
    exit 2
    ;;
esac

usage() {
  /bin/echo "Usage: $0 [--launch-only] [--clean-legacy]"
  /bin/echo "  --launch-only   Open the installed canonical preview without rebuilding"
  /bin/echo "  --clean-legacy  Move old native app copies and raw build/test products to Trash"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch-only) BUILD_CURRENT=0 ;;
    --clean-legacy) CLEAN_LEGACY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) /bin/echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

stop_preview_app() {
  /usr/bin/pgrep -x KaisolaMacPreview >/dev/null 2>&1 || return 0
  /usr/bin/pkill -TERM -x KaisolaMacPreview 2>/dev/null || true

  local attempt
  for ((attempt = 0; attempt < 50; attempt += 1)); do
    /usr/bin/pgrep -x KaisolaMacPreview >/dev/null 2>&1 || {
      # Give the detached broker a moment to observe the closed controller
      # socket before the replacement app tries to reclaim its durable PTYs.
      /bin/sleep 0.35
      return 0
    }
    /bin/sleep 0.1
  done

  /usr/bin/pkill -KILL -x KaisolaMacPreview 2>/dev/null || true
  /bin/sleep 0.35
}

build_current_source() {
  local version build_number
  version="$(/usr/bin/env node -p "require(process.argv[1]).version" "$ROOT/package.json")"
  build_number="$(git -C "$ROOT" rev-list --count HEAD)"

  /bin/mkdir -p "$DERIVED_DATA"
  /usr/bin/touch "$DERIVED_DATA/.metadata_never_index"
  /bin/echo "Building Kaisola Preview $version from current source…"
  /usr/bin/xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS,arch=$(uname -m)" \
    ONLY_ACTIVE_ARCH=YES \
    KAISOLA_PACKAGE_BROKER_HELPER=1 \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    build

  if [[ ! -x "$SOURCE_APP/Contents/MacOS/KaisolaMacPreview" ]]; then
    /bin/echo "Build completed without the expected app: $SOURCE_APP" >&2
    exit 1
  fi
  if [[ ! -x "$SOURCE_APP/Contents/Resources/BrokerHelper/bin/kaisola-broker-bootstrap" ]]; then
    /bin/echo "Build completed without the packaged broker helper." >&2
    exit 1
  fi

  local staging
  staging="${APP%.app}.installing-$$.app"
  /bin/mkdir -p "$(dirname "$APP")"
  /bin/rm -rf "$staging"
  /usr/bin/ditto "$SOURCE_APP" "$staging"

  # Stop only the native preview binary; Electron's Kaisola and all broker-owned
  # PTYs remain untouched. The replacement app is reproducible from this build.
  stop_preview_app
  /bin/rm -rf "$APP"
  /bin/mv "$staging" "$APP"
  /bin/echo "Installed one canonical app: $APP"
}

# xcodebuild registers every Debug/test product with Launch Services, including
# products below .noindex folders. That is why Spotlight can offer a pile of
# visually identical KaisolaMacPreview builds even though only one is installed.
# Keep the reproducible build products on disk for fast incremental builds, but
# unregister each non-canonical copy on every launcher run. The installed app is
# registered again immediately afterwards.
unregister_noncanonical_products() {
  shopt -s nullglob
  local product
  for product in \
    "$ROOT"/.build/KaisolaNative*.noindex/Build/Products/*/KaisolaMacPreview.app \
    "$HOME"/Library/Developer/Xcode/DerivedData/KaisolaMac-*/Build/Products/*/KaisolaMacPreview.app \
    "$HOME"/Library/Developer/Xcode/DerivedData/KaisolaMac-*/Index.noindex/Build/Products/*/KaisolaMacPreview.app; do
    [[ "$product" == "$APP" ]] && continue
    "$LSREGISTER" -u "$product" 2>/dev/null || true
  done
  shopt -u nullglob
}

move_to_trash() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  [[ "$target" != "$APP" ]] || return 0

  local base destination suffix collision
  base="$(basename "$target")"
  suffix="$(date +%Y%m%d-%H%M%S)-$$"
  destination="$HOME/.Trash/${base%.app}-$suffix.app"
  collision=1
  while [[ -e "$destination" ]]; do
    destination="$HOME/.Trash/${base%.app}-$suffix-$collision.app"
    collision=$((collision + 1))
  done
  /bin/mkdir -p "$HOME/.Trash"
  "$LSREGISTER" -u "$target" 2>/dev/null || true
  /bin/mv "$target" "$destination"
  /bin/echo "Moved legacy copy to Trash: $target"
}

clean_legacy_copies() {
  move_to_trash "$HOME/Applications/KaisolaMacPreview.app"
  move_to_trash "$HOME/Applications/Kaisola Native (Dev).app"
  move_to_trash "$ROOT/native/KaisolaMac/build/Build/Products/Debug/KaisolaMacPreview.app"

  shopt -s nullglob
  local product
  for product in "$ROOT"/.build/KaisolaNative*.noindex/Build/Products/*/KaisolaMacPreview.app; do
    move_to_trash "$product"
  done
  for product in "$HOME"/Library/Developer/Xcode/DerivedData/KaisolaMac-*/Build/Products/*/KaisolaMacPreview.app; do
    move_to_trash "$product"
  done
  for product in "$HOME"/Library/Developer/Xcode/DerivedData/KaisolaMac-*/Index.noindex/Build/Products/*/KaisolaMacPreview.app; do
    move_to_trash "$product"
  done
  shopt -u nullglob
}

broker_alive() {
  [[ -f "$BROKER_INFO" ]] || return 1
  local pid
  pid="$(/usr/bin/plutil -extract pid raw "$BROKER_INFO" 2>/dev/null || true)"
  [[ -n "$pid" ]] && /bin/kill -0 "$pid" 2>/dev/null
}

start_broker_if_needed() {
  local helper="$APP/Contents/Resources/BrokerHelper"
  if broker_alive; then
    /bin/echo "Using the running $PROFILE_NAME broker."
    return 0
  fi

  if [[ ! -d "$helper" ]]; then
    /bin/echo "The canonical preview has no broker helper: $helper" >&2
    /bin/echo "Run without --launch-only to rebuild it from current source." >&2
    exit 1
  fi

  /bin/echo "Starting the isolated $PROFILE_NAME broker…"
  /usr/bin/env node -e '
    const fs=require("fs"),os=require("os"),path=require("path"),crypto=require("crypto"),{spawnSync}=require("child_process");
    const helper=process.argv[1],profileName=process.argv[2];
    const manifest=JSON.parse(fs.readFileSync(path.join(helper,"manifest.json"),"utf8"));
    const profileRoot=path.join(os.homedir(),"Library","Application Support",profileName);
    const brokerRoot=path.join(profileRoot,"session-broker");
    fs.mkdirSync(brokerRoot,{recursive:true,mode:0o700});
    const socketDir=path.join(os.homedir(),".kaisola-session");
    fs.mkdirSync(socketDir,{recursive:true,mode:0o700});
    const launchFile=path.join(brokerRoot,"launch-native-"+crypto.randomUUID()+".json");
    const launch={protocol:2,securityEpoch:1,implementationVersion:manifest.brokerImplementationVersion,packageSchema:manifest.schemaVersion,packageVersion:manifest.packageVersion,token:crypto.randomBytes(32).toString("hex"),socketPath:path.join(socketDir,crypto.randomBytes(9).toString("hex")+".sock"),infoFile:path.join(brokerRoot,"broker.json"),lockFile:path.join(brokerRoot,"broker.lock"),storageDir:path.join(profileRoot,"terminal-cache"),logFile:path.join(brokerRoot,"broker.log"),startedAt:Date.now(),version:"native-preview-dev",smoke:false};
    fs.writeFileSync(launchFile,JSON.stringify(launch),{mode:0o600});
    const r=spawnSync(path.join(helper,"bin","kaisola-broker-bootstrap"),["--launch",launchFile],{encoding:"utf8",env:{...process.env,KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER:"1"}});
    if(r.status!==0){console.error(String(r.stderr||r.stdout).trim());process.exit(1);}
    console.log("  "+String(r.stdout).trim());
  ' "$helper" "$PROFILE_NAME"
}

if [[ "$BUILD_CURRENT" -eq 1 ]]; then
  build_current_source
elif [[ ! -x "$APP/Contents/MacOS/KaisolaMacPreview" ]]; then
  /bin/echo "Canonical preview not found at: $APP" >&2
  /bin/echo "Run without --launch-only to build and install it." >&2
  exit 1
fi

if [[ "$CLEAN_LEGACY" -eq 1 ]]; then
  clean_legacy_copies
fi

unregister_noncanonical_products
"$LSREGISTER" -f -R -trusted "$APP" 2>/dev/null || true

start_broker_if_needed
/bin/echo "Launching Kaisola Preview ($PROFILE_NAME profile)…"
stop_preview_app
# Launch Services detaches the app from the calling shell, so the preview stays
# open when this script returns (including from npm and non-interactive shells).
# `-n` is safe because stop_preview_app has already closed the prior instance.
/usr/bin/open -n --env KAISOLA_NATIVE_BROKER_PROFILE="$PROFILE_ROUTE" "$APP"
/bin/echo
/bin/echo "Ready: open a project with ⌘O, a terminal with ⌘T, or files with ⌘B."
