#!/usr/bin/env bash
# Launch the native preview against an isolated development broker so the full
# agent workspace (create terminals, run Claude/Codex agents, type into them)
# works immediately — without touching the Electron daily driver or its broker.
#
#   scripts/native-preview-dev.sh
#
# The preview's own state lives under the "Kaisola Dev" profile, separate from
# every installed app.
set -euo pipefail

APP="${KAISOLA_NATIVE_APP:-$HOME/Applications/Kaisola Native (Dev).app}"
if [[ ! -d "$APP" ]]; then
  echo "Native preview app not found at: $APP" >&2
  echo "Set KAISOLA_NATIVE_APP to its path, or reinstall the dev build." >&2
  exit 1
fi

HELPER="$APP/Contents/Resources/BrokerHelper"
BROKER_INFO="$HOME/Library/Application Support/Kaisola Dev/session-broker/broker.json"

broker_alive() {
  [[ -f "$BROKER_INFO" ]] || return 1
  local pid
  pid="$(/usr/bin/plutil -extract pid raw "$BROKER_INFO" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

if broker_alive; then
  echo "Using the running development broker."
else
  echo "Starting a development broker…"
  manifest="$HELPER/manifest.json"
  node -e '
    const fs=require("fs"),os=require("os"),path=require("path"),crypto=require("crypto"),{spawnSync}=require("child_process");
    const helper=process.argv[1];
    const manifest=JSON.parse(fs.readFileSync(path.join(helper,"manifest.json"),"utf8"));
    const brokerRoot=path.join(os.homedir(),"Library","Application Support","Kaisola Dev","session-broker");
    fs.mkdirSync(brokerRoot,{recursive:true,mode:0o700});
    const socketDir=path.join(os.homedir(),".kaisola-session");
    fs.mkdirSync(socketDir,{recursive:true,mode:0o700});
    const launchFile=path.join(brokerRoot,"launch-native-"+crypto.randomUUID()+".json");
    const launch={protocol:2,securityEpoch:1,implementationVersion:manifest.brokerImplementationVersion,packageSchema:manifest.schemaVersion,packageVersion:manifest.packageVersion,token:crypto.randomBytes(32).toString("hex"),socketPath:path.join(socketDir,crypto.randomBytes(9).toString("hex")+".sock"),infoFile:path.join(brokerRoot,"broker.json"),lockFile:path.join(brokerRoot,"broker.lock"),storageDir:path.join(os.homedir(),"Library","Application Support","Kaisola Dev","terminal-cache"),logFile:path.join(brokerRoot,"broker.log"),startedAt:Date.now(),version:"native-preview-dev",smoke:false};
    fs.writeFileSync(launchFile,JSON.stringify(launch),{mode:0o600});
    const r=spawnSync(path.join(helper,"bin","kaisola-broker-bootstrap"),["--launch",launchFile],{encoding:"utf8",env:{...process.env,KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER:"1"}});
    if(r.status!==0){console.error(String(r.stderr||r.stdout).trim());process.exit(1);}
    console.log("  "+String(r.stdout).trim());
  ' "$HELPER"
fi

echo "Launching the native preview (Kaisola Dev profile)…"
# Exec the bundle binary directly with the profile env var; `open --env` is
# unreliable when an instance is already running.
pkill -x KaisolaMacPreview 2>/dev/null || true
KAISOLA_NATIVE_USE_DEV_PROFILE=1 "$APP/Contents/MacOS/KaisolaMacPreview" >/dev/null 2>&1 &
echo
echo "Ready. Use ⌘T for a terminal, or File ▸ New Agent Session ▸ Claude/Codex."
