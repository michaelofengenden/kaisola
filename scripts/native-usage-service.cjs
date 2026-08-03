#!/usr/bin/env node
'use strict'

// A stdout-only bridge from the signed native app to the provider limit
// readers already used by Electron. It never sends a model prompt: Codex uses
// account/rateLimits/read and Claude uses the Agent SDK's control-only usage
// request. The Swift client receives one small, provider-neutral JSON shape.

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { agentEnv } = require('../runtime/node-broker/ipc/shellEnv.cjs')
const { codexUsage, readClaudeSdkUsage } = require('../runtime/node-broker/ipc/usageHandler.cjs')

const CLAUDE_SDK_VERSION = '0.3.205'

function finite(value, minimum = 0, maximum = Number.MAX_SAFE_INTEGER) {
  if (value == null || value === '') return null
  const number = Number(value)
  return Number.isFinite(number) && number >= minimum && number <= maximum ? number : null
}

function resetEpoch(value) {
  if (typeof value === 'string') {
    const milliseconds = Date.parse(value)
    return Number.isFinite(milliseconds) ? Math.floor(milliseconds / 1000) : null
  }
  const valueNumber = finite(value)
  if (valueNumber == null) return null
  return Math.floor(valueNumber > 10_000_000_000 ? valueNumber / 1000 : valueNumber)
}

function normalizedWindow(label, raw) {
  if (!raw || typeof raw !== 'object') return null
  const usedPercent = finite(raw.usedPercent ?? raw.used_percentage ?? raw.utilization, 0, 100)
  const resetsAt = resetEpoch(raw.resetsAt ?? raw.resets_at ?? raw.resetAt ?? raw.reset_at)
  if (usedPercent == null && resetsAt == null) return null
  return {
    ...(label == null ? {} : { label }),
    ...(usedPercent == null ? {} : { usedPercent }),
    ...(resetsAt == null ? {} : { resetsAt }),
  }
}

/** Name a lone Codex window from how far out it resets.
 *
 * A window resetting within a day is the short rolling limit; anything further
 * is the weekly one. The boundary sits at 24h because the two real windows are
 * 5 hours and 7 days apart — nothing legitimate lands near it. A window with no
 * reset time at all keeps the historical name rather than guessing. */
function codexWindowLabel(win, now = Date.now()) {
  const resetsAt = finite(win && win.resetsAt)
  if (resetsAt == null) return '5 hour'
  const remainingHours = (resetsAt * 1000 - now) / 3_600_000
  return remainingHours > 24 ? 'Weekly' : '5 hour'
}

function normalizeCodex(raw, now = Date.now()) {
  if (!raw || raw.ok !== true) {
    return {
      provider: 'codex',
      displayName: 'Codex',
      ok: false,
      sourceLabel: 'Codex CLI app-server',
      message: String(raw?.message || 'Codex account limits are unavailable.'),
      windows: [],
      updatedAt: now,
    }
  }
  // Label each window by how long it actually runs, not by its position.
  //
  // These were hardcoded 'primary' -> '5 hour' and 'secondary' -> 'Weekly'.
  // Codex now reports a weekly limit only, so that single window arrives as
  // `primary` and got drawn as "5 hour ... resets in 4d" — a five-hour window
  // that resets in four days, which is nonsense on its face. Deriving the name
  // from the reset horizon is right whichever slot a window shows up in, and
  // keeps working if Codex changes its mind again.
  const primary = normalizedWindow(null, raw.primary)
  const secondary = normalizedWindow(null, raw.secondary)
  // With both windows present the slots mean what they always meant, and
  // position is the better evidence. It is the *lone* window that is ambiguous
  // — Codex now reports a weekly limit only, and it arrives as `primary` — so
  // only then is the name inferred from how far out it resets.
  const windows = primary && secondary
    ? [{ ...primary, label: '5 hour' }, { ...secondary, label: 'Weekly' }]
    : [primary || secondary].filter(Boolean).map((win) => ({ ...win, label: codexWindowLabel(win, now) }))
  return {
    provider: 'codex',
    displayName: 'Codex',
    ok: windows.length > 0,
    sourceLabel: 'Codex CLI app-server',
    experimental: false,
    ...(typeof raw.email === 'string' && raw.email.trim() ? { account: raw.email.trim() } : {}),
    ...(typeof raw.plan === 'string' && raw.plan.trim() ? { plan: raw.plan.trim() } : {}),
    windows,
    ...(windows.length ? {} : { message: 'Codex returned no account limit windows.' }),
    updatedAt: finite(raw.updatedAt) || now,
  }
}

function normalizeClaude(raw, now = Date.now()) {
  if (!raw || raw.ok !== true) {
    return {
      provider: 'claude',
      displayName: 'Claude',
      ok: false,
      sourceLabel: `Claude Agent SDK ${CLAUDE_SDK_VERSION}`,
      experimental: true,
      message: String(raw?.message || 'Claude Agent SDK usage is unavailable.'),
      windows: [],
      updatedAt: now,
    }
  }
  const limits = raw.limits && typeof raw.limits === 'object' ? raw.limits : {}
  const windows = [
    normalizedWindow('5 hour', limits.fiveHour),
    normalizedWindow('7 day', limits.sevenDay),
    ...(Array.isArray(limits.modelScoped)
      ? limits.modelScoped.map((entry) => normalizedWindow(String(entry?.label || 'Model').slice(0, 80), entry))
      : []),
  ].filter(Boolean)
  const account = [raw.email, raw.organization]
    .filter((value) => typeof value === 'string' && value.trim())
    .map((value) => value.trim())
    .join(' · ')
  return {
    provider: 'claude',
    displayName: 'Claude',
    ok: windows.length > 0,
    sourceLabel: raw.sourceLabel || `Claude Agent SDK ${CLAUDE_SDK_VERSION}`,
    experimental: true,
    ...(account ? { account } : {}),
    ...(typeof raw.subscriptionType === 'string' && raw.subscriptionType.trim()
      ? { plan: raw.subscriptionType.trim() }
      : {}),
    windows,
    ...(windows.length ? {} : {
      message: raw.rateLimitsAvailable === false
        ? 'Sign in with a Claude.ai subscription to read plan limits.'
        : 'Claude returned no account limit windows yet.',
    }),
    updatedAt: finite(raw.updatedAt) || now,
  }
}

function executableOnPath(name, env) {
  const candidates = String(env.PATH || '').split(path.delimiter).filter(Boolean)
  for (const directory of candidates) {
    const candidate = path.join(directory, name)
    try {
      fs.accessSync(candidate, fs.constants.X_OK)
      if (fs.statSync(candidate).isFile()) return fs.realpathSync(candidate)
    } catch { /* next PATH entry */ }
  }
  return null
}

function fixture(now = Date.now(), provider) {
  const providers = [
      normalizeClaude({
        ok: true,
        sourceLabel: `Claude Agent SDK ${CLAUDE_SDK_VERSION}`,
        subscriptionType: 'max',
        limits: {
          fiveHour: { usedPercent: 38, resetsAt: Math.floor(now / 1000) + 7_200 },
          sevenDay: { usedPercent: 16, resetsAt: Math.floor(now / 1000) + 345_600 },
          modelScoped: [],
        },
        updatedAt: now,
      }, now),
      normalizeCodex({
        ok: true,
        plan: 'plus',
        primary: { usedPercent: 24, resetsAt: Math.floor(now / 1000) + 5_400 },
        secondary: { usedPercent: 11, resetsAt: Math.floor(now / 1000) + 432_000 },
        updatedAt: now,
      }, now),
    ]
  return { providers: provider ? providers.filter((value) => value.provider === provider) : providers }
}

async function readUsage({ provider } = {}) {
  if (provider != null && provider !== 'claude' && provider !== 'codex') {
    throw new Error('Unknown usage provider. Expected claude or codex.')
  }
  const now = Date.now()
  if (process.env.KAISOLA_NATIVE_USAGE_FIXTURE === '1') return fixture(now, provider)

  const env = agentEnv()
  const codexHome = typeof env.CODEX_HOME === 'string' && env.CODEX_HOME.trim()
    ? env.CODEX_HOME.trim()
    : undefined
  const claudeBase = path.resolve(
    typeof env.CLAUDE_CONFIG_DIR === 'string' && env.CLAUDE_CONFIG_DIR.trim()
      ? env.CLAUDE_CONFIG_DIR.trim().replace(/^~(?=\/|$)/, os.homedir())
      : path.join(os.homedir(), '.claude'),
  )
  const claudeExecutable = executableOnPath('claude', env)

  const tasks = []
  if (provider == null || provider === 'claude') {
    const claudePromise = claudeExecutable
      ? readClaudeSdkUsage(claudeBase, {
          env,
          now,
          pathToClaudeCodeExecutable: claudeExecutable,
        }).catch((error) => ({ ok: false, message: error.message }))
      : Promise.resolve({ ok: false, message: 'Claude CLI not found on your login-shell PATH.' })
    tasks.push(claudePromise.then((claude) => normalizeClaude(claude, now)))
  }
  if (provider == null || provider === 'codex') {
    tasks.push(codexUsage(codexHome, { env })
      .catch((error) => ({ ok: false, message: error.message }))
      .then((codex) => normalizeCodex(codex, now)))
  }
  return { providers: await Promise.all(tasks) }
}

function parseArguments(argv) {
  if (argv.length === 0) return {}
  if (argv.length === 2 && argv[0] === '--provider' && (argv[1] === 'claude' || argv[1] === 'codex')) {
    return { provider: argv[1] }
  }
  throw new Error('Usage: native-usage-service.cjs [--provider claude|codex]')
}

if (require.main === module) {
  let options
  try {
    options = parseArguments(process.argv.slice(2))
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ providers: [], error: String(error?.message || error) })}\n`)
    process.exitCode = 2
  }
  if (options) readUsage(options)
    .then((value) => process.stdout.write(`${JSON.stringify(value)}\n`))
    .catch((error) => {
      process.stdout.write(`${JSON.stringify({ providers: [], error: String(error?.message || error) })}\n`)
      process.exitCode = 1
    })
}

module.exports = {
  executableOnPath,
  fixture,
  normalizeClaude,
  normalizeCodex,
  normalizedWindow,
  parseArguments,
  readUsage,
}
