#!/bin/sh
set -euo pipefail
launch_agents="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
mkdir -p "${launch_agents}"
cp "${SRCROOT}/BrokerHelper/com.kaisola.mac.preview.broker-bootstrap.plist" "${launch_agents}/com.kaisola.mac.preview.broker-bootstrap.plist"

if [[ "${CONFIGURATION}" != "Release" && "${CONFIGURATION}" != "LocalRelease" && "${KAISOLA_PACKAGE_BROKER_HELPER:-0}" != "1" ]]; then
  exit 0
fi

runtime_arm64="${KAISOLA_NODE_RUNTIME_ARM64:-${SRCROOT}/.artifacts/node-v22.23.1-darwin-arm64/bin/node}"
runtime_x64="${KAISOLA_NODE_RUNTIME_X86_64:-${SRCROOT}/.artifacts/node-v22.23.1-darwin-x64/bin/node}"
if [[ ! -x "${runtime_arm64}" ]]; then
  echo "Missing pinned arm64 Node runtime. Run: node scripts/download-native-node-runtime.cjs arm64" >&2
  exit 1
fi

args=(
  --output "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BrokerHelper"
  --runtime-arm64 "${runtime_arm64}"
  --bootstrap "${BUILT_PRODUCTS_DIR}/KaisolaBrokerBootstrap"
  --entitlements "${SRCROOT}/BrokerHelper/BrokerHelper.entitlements"
)
if [[ " ${ARCHS} " == *" x86_64 "* ]]; then
  if [[ ! -x "${runtime_x64}" ]]; then
    echo "Missing pinned x86_64 Node runtime. Run: node scripts/download-native-node-runtime.cjs x86_64" >&2
    exit 1
  fi
  args+=(--runtime-x86_64 "${runtime_x64}")
fi
if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  args+=(--sign-identity "${EXPANDED_CODE_SIGN_IDENTITY}" --require-signatures)
fi
/usr/bin/env node "${SRCROOT}/../../scripts/native-broker-package.cjs" "${args[@]}"

