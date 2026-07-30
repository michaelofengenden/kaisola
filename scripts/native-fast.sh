#!/usr/bin/env bash
# Lowest-latency native Swift edit -> build -> run loop.
#
# Unlike native-dev.sh, this lane launches the stable DerivedData product
# directly. It deliberately skips app installation, Launch Services cleanup,
# and broker-helper packaging while the selected detached broker is alive.
# Use native-dev.sh whenever packaging, helper, signing, entitlements, update,
# or production-profile behavior is part of the change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT="$ROOT/native/KaisolaMac/KaisolaMac.xcodeproj"
SCHEME="Kaisola"
CONFIGURATION="Debug"
DERIVED_DATA="${KAISOLA_NATIVE_DERIVED_DATA:-$ROOT/.build/Kaisola.noindex}"
SOURCE_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/Kaisola.app"
CANONICAL_DEV_APP="${KAISOLA_NATIVE_APP:-$HOME/Applications/Kaisola Dev.app}"
PROFILE_ROUTE="${KAISOLA_NATIVE_BROKER_PROFILE:-native}"
BUILD_CURRENT=1
LAUNCH_CURRENT=1
REFRESH_HELPER=0
SKIP_HELPER=0
VERBOSE=0

case "$PROFILE_ROUTE" in
  native) PROFILE_NAME="Kaisola Native" ;;
  development) PROFILE_NAME="Kaisola Dev" ;;
  *)
    /bin/echo "KAISOLA_NATIVE_BROKER_PROFILE must be native or development." >&2
    exit 2
    ;;
esac

BROKER_INFO="$HOME/Library/Application Support/$PROFILE_NAME/session-broker/broker.json"

usage() {
  /bin/echo "Usage: $0 [--build-only | --launch-only] [--refresh-helper | --skip-helper] [--verbose]"
  /bin/echo ""
  /bin/echo "  --build-only      Incrementally build without launching the app"
  /bin/echo "  --launch-only     Launch the existing DerivedData product"
  /bin/echo "  --refresh-helper  Repackage the broker helper during this build"
  /bin/echo "  --skip-helper     Skip helper packaging (isolated build timing only)"
  /bin/echo "  --verbose         Show the full xcodebuild log"
  /bin/echo ""
  /bin/echo "Environment:"
  /bin/echo "  KAISOLA_NATIVE_BROKER_PROFILE=native|development"
  /bin/echo "  KAISOLA_NATIVE_DERIVED_DATA=/absolute/stable/path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) LAUNCH_CURRENT=0 ;;
    --launch-only) BUILD_CURRENT=0 ;;
    --refresh-helper) REFRESH_HELPER=1 ;;
    --skip-helper) SKIP_HELPER=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) /bin/echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$BUILD_CURRENT" -eq 0 && "$REFRESH_HELPER" -eq 1 ]]; then
  /bin/echo "--refresh-helper requires a build." >&2
  exit 2
fi
if [[ "$BUILD_CURRENT" -eq 0 && "$SKIP_HELPER" -eq 1 ]]; then
  /bin/echo "--skip-helper requires a build." >&2
  exit 2
fi
if [[ "$REFRESH_HELPER" -eq 1 && "$SKIP_HELPER" -eq 1 ]]; then
  /bin/echo "--refresh-helper and --skip-helper are mutually exclusive." >&2
  exit 2
fi
if [[ "$SKIP_HELPER" -eq 1 && "${KAISOLA_NATIVE_TIMING_ISOLATED:-0}" != "1" ]]; then
  /bin/echo "--skip-helper is reserved for the isolated native:timing runner." >&2
  exit 2
fi
if [[ "$BUILD_CURRENT" -eq 0 && "$LAUNCH_CURRENT" -eq 0 ]]; then
  /bin/echo "--build-only and --launch-only are mutually exclusive." >&2
  exit 2
fi

broker_alive() {
  [[ -f "$BROKER_INFO" ]] || return 1
  local pid
  pid="$(/usr/bin/plutil -extract pid raw "$BROKER_INFO" 2>/dev/null || true)"
  [[ -n "$pid" ]] && /bin/kill -0 "$pid" 2>/dev/null
}

helper_input_digest() {
  /usr/bin/env node - "$ROOT" <<'NODE'
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')

const root = process.argv[2]
const inputs = [
  'native/KaisolaMac/BrokerBootstrap',
  'native/KaisolaMac/BrokerHelper',
  'native/KaisolaMac/Shared',
  'native/KaisolaMac/project.yml',
  'native/KaisolaCore/Package.swift',
  'native/KaisolaCore/Sources/KaisolaBrokerProtocol',
  'runtime/node-broker',
  'scripts/native-broker-package.cjs',
  'scripts/native-usage-service.cjs',
  'package.json',
  'package-lock.json',
]
const files = []
const visit = (relative) => {
  const absolute = path.join(root, relative)
  if (!fs.existsSync(absolute)) return
  const stat = fs.lstatSync(absolute)
  if (stat.isSymbolicLink()) return
  if (stat.isDirectory()) {
    for (const name of fs.readdirSync(absolute).sort()) visit(path.posix.join(relative, name))
  } else if (stat.isFile()) {
    files.push(relative)
  }
}
for (const input of inputs) visit(input)
const hash = crypto.createHash('sha256')
for (const relative of files.sort()) {
  hash.update(relative)
  hash.update('\0')
  hash.update(fs.readFileSync(path.join(root, relative)))
  hash.update('\0')
}
process.stdout.write(hash.digest('hex'))
NODE
}

stop_exact_app() {
  local app="$1"
  local executable="$app/Contents/MacOS/Kaisola"
  local pid command
  local -a pids=()

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == "$executable" || "$command" == "$executable "* ]]; then
      pids+=("$pid")
    fi
  done < <(/usr/bin/pgrep -f "$executable" 2>/dev/null || true)

  [[ "${#pids[@]}" -gt 0 ]] || return 0
  /bin/kill -TERM "${pids[@]}" 2>/dev/null || true

  local attempt
  for ((attempt = 0; attempt < 30; attempt += 1)); do
    local remaining=0
    for pid in "${pids[@]}"; do
      /bin/kill -0 "$pid" 2>/dev/null && remaining=$((remaining + 1))
    done
    [[ "$remaining" -eq 0 ]] && {
      # Let the detached broker observe the closed controller before reattach.
      /bin/sleep 0.20
      return 0
    }
    /bin/sleep 0.1
  done

  for pid in "${pids[@]}"; do
    /bin/kill -KILL "$pid" 2>/dev/null || true
  done
  /bin/sleep 0.20
}

build_current_source() {
  local version build_number package_helper elapsed helper_digest previous_helper_digest helper_reason helper_stamp
  version="$(/usr/bin/env node -p "require(process.argv[1]).version" "$ROOT/package.json")"
  build_number="$(git -C "$ROOT" rev-list --count HEAD)"
  package_helper=0
  helper_reason="unchanged helper inputs"
  helper_stamp="$DERIVED_DATA/.kaisola-broker-helper-inputs.sha256"
  helper_digest="$(helper_input_digest)"
  previous_helper_digest="$(/bin/cat "$helper_stamp" 2>/dev/null || true)"

  # A live detached broker makes the helper irrelevant to an ordinary UI/code
  # iteration. Repackage when helper inputs changed so the next safe broker
  # replacement cannot accidentally launch stale code. A clean profile still
  # gets a self-contained first build. The explicit skip is reserved for a
  # fresh, isolated timing cache and never mutates the canonical fast cache.
  if [[ "$SKIP_HELPER" -eq 1 ]]; then
    helper_reason="explicit isolated timing skip"
  elif [[ "$REFRESH_HELPER" -eq 1 ]]; then
    package_helper=1
    helper_reason="explicit refresh"
  elif [[ -n "$previous_helper_digest" && "$previous_helper_digest" != "$helper_digest" ]]; then
    package_helper=1
    helper_reason="helper inputs changed"
  elif [[ -z "$previous_helper_digest" && -d "$SOURCE_APP/Contents/Resources/BrokerHelper" ]]; then
    package_helper=1
    helper_reason="initialize helper input seal"
  elif ! broker_alive && [[ ! -x "$SOURCE_APP/Contents/Resources/BrokerHelper/bin/kaisola-broker-bootstrap" ]]; then
    package_helper=1
    helper_reason="no live broker or packaged helper"
  fi

  /bin/mkdir -p "$DERIVED_DATA"
  /usr/bin/touch "$DERIVED_DATA/.metadata_never_index"
  /bin/echo "Fast-building Kaisola $version (active arch, helper=$package_helper; $helper_reason)…"

  local -a log_args=()
  [[ "$VERBOSE" -eq 1 ]] || log_args+=("-quiet")
  SECONDS=0
  /usr/bin/xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS,arch=$(uname -m)" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackageUpdates \
    "${log_args[@]}" \
    ONLY_ACTIVE_ARCH=YES \
    ARCHS="$(uname -m)" \
    SWIFT_COMPILATION_MODE=incremental \
    COMPILER_INDEX_STORE_ENABLE=NO \
    BUILD_ACTIVE_RESOURCES_ONLY=YES \
    PRODUCT_BUNDLE_IDENTIFIER=com.kaisola.mac.dev \
    INFOPLIST_KEY_CFBundleDisplayName="Kaisola Dev" \
    KAISOLA_PACKAGE_BROKER_HELPER="$package_helper" \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    build
  elapsed="$SECONDS"

  if [[ ! -x "$SOURCE_APP/Contents/MacOS/Kaisola" ]]; then
    /bin/echo "Build completed without the expected app: $SOURCE_APP" >&2
    exit 1
  fi
  if [[ "$package_helper" -eq 1 && ! -x "$SOURCE_APP/Contents/Resources/BrokerHelper/bin/kaisola-broker-bootstrap" ]]; then
    /bin/echo "Build completed without the requested broker helper." >&2
    exit 1
  fi

  # Advance the source stamp only after xcodebuild and requested packaging
  # succeed. An interrupted helper refresh therefore remains dirty next run.
  /bin/echo "$helper_digest" >"$helper_stamp"

  /bin/echo "Fast build finished in ${elapsed}s: $SOURCE_APP"
}

if [[ "$BUILD_CURRENT" -eq 1 ]]; then
  build_current_source
elif [[ ! -x "$SOURCE_APP/Contents/MacOS/Kaisola" ]]; then
  /bin/echo "Fast development product not found at: $SOURCE_APP" >&2
  /bin/echo "Run without --launch-only to build it." >&2
  exit 1
fi

if [[ "$LAUNCH_CURRENT" -eq 0 ]]; then
  exit 0
fi

if ! broker_alive && [[ ! -x "$SOURCE_APP/Contents/Resources/BrokerHelper/bin/kaisola-broker-bootstrap" ]]; then
  /bin/echo "The $PROFILE_NAME broker is not running and this fast product has no helper." >&2
  /bin/echo "Run: $0 --refresh-helper" >&2
  exit 1
fi

# Never touch the production /Applications app. Stop only the direct product
# and the canonical development copy, which share the same dev bundle/profile.
stop_exact_app "$SOURCE_APP"
stop_exact_app "$CANONICAL_DEV_APP"

/bin/echo "Launching the DerivedData executable directly ($PROFILE_NAME profile)…"
LOG_DIR="$DERIVED_DATA/Logs"
LOG_FILE="$LOG_DIR/native-fast-app.log"
/bin/mkdir -p "$LOG_DIR"
/usr/bin/nohup /usr/bin/env \
  KAISOLA_NATIVE_BROKER_PROFILE="$PROFILE_ROUTE" \
  KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER=1 \
  "$SOURCE_APP/Contents/MacOS/Kaisola" >>"$LOG_FILE" 2>&1 &
APP_PID=$!
/bin/sleep 0.25
if ! /bin/kill -0 "$APP_PID" 2>/dev/null; then
  /bin/echo "The fast app exited during launch. Inspect: $LOG_FILE" >&2
  exit 1
fi
/bin/echo "Ready: pid=$APP_PID app=$SOURCE_APP log=$LOG_FILE"
