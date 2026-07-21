const MANIFEST_KEY = 'kaisola-window-manifest-v1'
const MANIFEST_VERSION = 1
const OPEN_AT_QUIT = 'open_at_quit'
const PARKED = 'parked'
const VALID_STATES = new Set([OPEN_AT_QUIT, PARKED])

// Saved-window slot range. freeSlot allocation (main.cjs) and every slot
// sanitizer must agree: a slot handed out above the sanitizers' cap would be
// dropped on the next parseManifest, orphaning that window's numbered store.
const MIN_SLOT = 2
const MAX_SLOT = 999_999

const safeSlot = (value) => {
  if (value == null) return null
  const slot = Number(value)
  return Number.isSafeInteger(slot) && slot >= MIN_SLOT && slot <= MAX_SLOT ? slot : undefined
}

const idForSlot = (slot) => slot == null ? 'primary' : `slot-${slot}`

const safeBounds = (raw) => {
  if (!raw || typeof raw !== 'object') return undefined
  const x = Number(raw.x)
  const y = Number(raw.y)
  const width = Number(raw.width)
  const height = Number(raw.height)
  if (![x, y, width, height].every(Number.isFinite)) return undefined
  if (Math.abs(x) > 10_000_000 || Math.abs(y) > 10_000_000 || width < 320 || width > 16_000 || height < 240 || height > 16_000) return undefined
  return { x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height) }
}

function sanitizeEntry(raw, now = Date.now()) {
  if (!raw || typeof raw !== 'object') return null
  const slot = safeSlot(raw.slot)
  if (slot === undefined || !VALID_STATES.has(raw.state)) return null
  const title = typeof raw.title === 'string' ? raw.title.replace(/\s+/g, ' ').trim().slice(0, 160) : ''
  const updatedAt = Number.isFinite(Number(raw.updatedAt)) && Number(raw.updatedAt) > 0
    ? Math.round(Number(raw.updatedAt))
    : now
  const projectCount = Number.isSafeInteger(Number(raw.projectCount))
    ? Math.max(0, Math.min(1_000, Number(raw.projectCount)))
    : undefined
  return {
    id: idForSlot(slot),
    slot,
    state: raw.state,
    updatedAt,
    ...(title ? { title } : {}),
    ...(projectCount == null ? {} : { projectCount }),
    ...(safeBounds(raw.bounds) ? { bounds: safeBounds(raw.bounds) } : {}),
    ...(raw.maximized === true ? { maximized: true } : {}),
    ...(raw.fullScreen === true ? { fullScreen: true } : {}),
  }
}

const sortEntries = (entries) => [...entries].sort((a, b) => {
  if (a.slot == null) return -1
  if (b.slot == null) return 1
  return a.slot - b.slot
})

function parseManifest(raw, now = Date.now()) {
  let parsed = raw
  if (typeof raw === 'string') {
    try { parsed = JSON.parse(raw) } catch { return [] }
  }
  const rows = Array.isArray(parsed) ? parsed : parsed?.version === MANIFEST_VERSION && Array.isArray(parsed.entries) ? parsed.entries : []
  const byId = new Map()
  for (const rawEntry of rows) {
    const entry = sanitizeEntry(rawEntry, now)
    if (!entry) continue
    const previous = byId.get(entry.id)
    if (!previous || entry.updatedAt >= previous.updatedAt) byId.set(entry.id, entry)
  }
  return sortEntries(byId.values())
}

const serializeManifest = (entries) => JSON.stringify({
  version: MANIFEST_VERSION,
  entries: parseManifest({ version: MANIFEST_VERSION, entries }),
})

function upsertEntry(entries, rawEntry, now = Date.now()) {
  const entry = sanitizeEntry({ ...rawEntry, updatedAt: rawEntry?.updatedAt ?? now }, now)
  if (!entry) return parseManifest({ version: MANIFEST_VERSION, entries }, now)
  const next = parseManifest({ version: MANIFEST_VERSION, entries }, now).filter((candidate) => candidate.id !== entry.id)
  next.push(entry)
  return sortEntries(next)
}

const removeEntry = (entries, id) => parseManifest({ version: MANIFEST_VERSION, entries }).filter((entry) => entry.id !== id)

function restoreCandidates(entries, liveIds = new Set()) {
  const seen = new Set(liveIds)
  return parseManifest({ version: MANIFEST_VERSION, entries }).filter((entry) => {
    if (entry.state !== OPEN_AT_QUIT || seen.has(entry.id)) return false
    seen.add(entry.id)
    return true
  })
}

const mostRecentParked = (entries) => parseManifest({ version: MANIFEST_VERSION, entries })
  .filter((entry) => entry.state === PARKED)
  .sort((a, b) => b.updatedAt - a.updatedAt)[0] ?? null

const occupiedSlots = (entries) => new Set(parseManifest({ version: MANIFEST_VERSION, entries }).flatMap((entry) => entry.slot == null ? [] : [entry.slot]))

const storeKeysForSlot = (slot) => {
  const suffix = slot == null ? '' : `-w${slot}`
  return [`kaisola-store${suffix}`, `kiasola-store${suffix}`, `pasola-store${suffix}`]
}

const slotFromStoreKey = (key) => {
  const match = /^(?:kaisola|kiasola|pasola)-store(?:-w([0-9]+))?$/.exec(String(key))
  if (!match) return undefined
  if (!match[1]) return null
  return safeSlot(Number(match[1]))
}

module.exports = {
  MANIFEST_KEY,
  MANIFEST_VERSION,
  MIN_SLOT,
  MAX_SLOT,
  safeSlot,
  OPEN_AT_QUIT,
  PARKED,
  idForSlot,
  sanitizeEntry,
  parseManifest,
  serializeManifest,
  upsertEntry,
  removeEntry,
  restoreCandidates,
  mostRecentParked,
  occupiedSlots,
  storeKeysForSlot,
  slotFromStoreKey,
}
