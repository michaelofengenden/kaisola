'use strict'

const {
  idForSlot,
  parseManifest,
  removeEntry: removeManifestEntry,
  serializeManifest,
  storeKeysForSlot,
} = require('./windowManifestPolicy.cjs')

const JOURNAL_KEY = 'kaisola-project-transfer-journal-v1'
const JOURNAL_VERSION = 1
const MAX_RECORDS = 8
const MAX_STORE_BYTES = 32 * 1024 * 1024
const VALID_ID = /^[A-Za-z0-9_-]{1,240}$/

const canonicalStoreKey = (slot) => storeKeysForSlot(slot)[0]

function safeSlot(value) {
  if (value == null) return null
  const slot = Number(value)
  return Number.isSafeInteger(slot) && slot >= 2 && slot <= 999_999 ? slot : undefined
}

function validStoreRaw(raw) {
  if (raw == null) return null
  if (typeof raw !== 'string' || Buffer.byteLength(raw, 'utf8') > MAX_STORE_BYTES) return undefined
  try {
    const envelope = JSON.parse(raw)
    if (!envelope || typeof envelope !== 'object' || !envelope.state || typeof envelope.state !== 'object') return undefined
    return raw
  } catch {
    return undefined
  }
}

function readWindowStore(get, slot) {
  for (const key of storeKeysForSlot(slot)) {
    const value = validStoreRaw(get(key))
    if (value !== null && value !== undefined) return { key, value }
  }
  return null
}

function recoveredProjectId(transferId) {
  return `proj-recovered-${String(transferId).replace(/[^A-Za-z0-9_-]/g, '').slice(-120)}`
}

/**
 * Fold one project out of a persisted Zustand envelope without touching any
 * other project's slice. This is the crash-recovery equivalent of the
 * renderer's post-ACK removal and is deliberately idempotent.
 */
function removeProjectFromStoreRaw(raw, projectId, transferId) {
  const checked = validStoreRaw(raw)
  if (checked === undefined || checked === null) throw new Error('Project transfer source store is unavailable.')
  const envelope = JSON.parse(checked)
  const state = envelope.state
  const tabs = Array.isArray(state.projectTabs) ? state.projectTabs : null
  if (!tabs) throw new Error('Project transfer source has no valid tab list.')
  const index = tabs.findIndex((tab) => tab?.id === projectId)
  if (index < 0) return checked

  const remaining = tabs.filter((tab) => tab?.id !== projectId)
  const slices = state.projectSlices && typeof state.projectSlices === 'object' && !Array.isArray(state.projectSlices)
    ? { ...state.projectSlices }
    : {}
  delete slices[projectId]
  state.projectSlices = slices

  if (remaining.length) {
    state.projectTabs = remaining
    if (state.activeProjectId === projectId) {
      state.activeProjectId = remaining[Math.min(index, remaining.length - 1)].id
    }
  } else {
    const id = recoveredProjectId(transferId)
    state.projectTabs = [{ id, workspacePath: null, hue: '#74834f', createdAt: Date.now() }]
    state.activeProjectId = id
    state.projectSlices = {}
  }
  return JSON.stringify(envelope)
}

function sanitizeRecord(raw) {
  if (!raw || typeof raw !== 'object' || !VALID_ID.test(String(raw.transferId ?? '')) || !VALID_ID.test(String(raw.projectId ?? ''))) return null
  const sourceSlot = safeSlot(raw.sourceSlot)
  const targetSlot = safeSlot(raw.targetSlot)
  if (sourceSlot === undefined || targetSlot === undefined) return null
  if (raw.targetKind !== 'existing' && raw.targetKind !== 'new') return null
  if (raw.phase !== 'prepared' && raw.phase !== 'target_committed') return null
  const sourceBeforeRaw = validStoreRaw(raw.sourceBeforeRaw)
  const sourceAfterRaw = validStoreRaw(raw.sourceAfterRaw)
  const targetBeforeRaw = validStoreRaw(raw.targetBeforeRaw)
  if (sourceBeforeRaw == null || sourceAfterRaw == null || targetBeforeRaw === undefined) return null
  return {
    transferId: String(raw.transferId),
    projectId: String(raw.projectId),
    sourceSlot,
    targetSlot,
    sourceId: idForSlot(sourceSlot),
    targetId: idForSlot(targetSlot),
    targetKind: raw.targetKind,
    closeSource: raw.closeSource === true,
    phase: raw.phase,
    createdAt: Number.isSafeInteger(raw.createdAt) ? raw.createdAt : Date.now(),
    sourceBeforeRaw,
    sourceAfterRaw,
    targetBeforeRaw,
  }
}

function parseJournal(raw) {
  if (raw == null) return []
  let parsed = raw
  if (typeof raw === 'string') {
    try { parsed = JSON.parse(raw) } catch { return [] }
  }
  const rows = parsed?.version === JOURNAL_VERSION && Array.isArray(parsed.records) ? parsed.records : []
  return rows.flatMap((row) => {
    const record = sanitizeRecord(row)
    return record ? [record] : []
  }).slice(-MAX_RECORDS)
}

const serializeJournal = (records) => JSON.stringify({
  version: JOURNAL_VERSION,
  records: records.map(sanitizeRecord).filter(Boolean).slice(-MAX_RECORDS),
})

function prepareProjectTransfer({ get, mutate, transferId, projectId, sourceSlot, targetSlot, targetKind, closeSource }) {
  const source = readWindowStore(get, sourceSlot)
  if (!source) throw new Error('The source window could not be made durable before moving its project.')
  const target = readWindowStore(get, targetSlot)
  const sourceAfterRaw = removeProjectFromStoreRaw(source.value, projectId, transferId)
  const record = sanitizeRecord({
    transferId,
    projectId,
    sourceSlot,
    targetSlot,
    targetKind,
    closeSource,
    phase: 'prepared',
    createdAt: Date.now(),
    sourceBeforeRaw: source.value,
    sourceAfterRaw,
    targetBeforeRaw: target?.value ?? null,
  })
  if (!record) throw new Error('The project transfer journal record was invalid.')
  const records = parseJournal(get(JOURNAL_KEY)).filter((candidate) => candidate.transferId !== transferId)
  if (records.some((candidate) => candidate.sourceId === record.sourceId || candidate.targetId === record.targetId)) {
    throw new Error('Another project move is still completing in one of these windows.')
  }
  mutate({ set: { [JOURNAL_KEY]: serializeJournal([...records, record]) } })
  return record
}

function markProjectTransferCommitted({ get, mutate, transferId }) {
  const records = parseJournal(get(JOURNAL_KEY))
  const index = records.findIndex((record) => record.transferId === transferId)
  if (index < 0) throw new Error('The project transfer journal entry is missing.')
  records[index] = { ...records[index], phase: 'target_committed' }
  mutate({ set: { [JOURNAL_KEY]: serializeJournal(records) } })
  return records[index]
}

function abortProjectTransfer({ get, mutate, transferId, manifestKey, projectionKey }) {
  const records = parseJournal(get(JOURNAL_KEY))
  const record = records.find((candidate) => candidate.transferId === transferId)
  if (!record || record.phase !== 'prepared') return { ok: false }
  const remaining = records.filter((candidate) => candidate.transferId !== transferId)
  const set = {}
  const deleted = new Set()
  if (remaining.length) set[JOURNAL_KEY] = serializeJournal(remaining)
  else deleted.add(JOURNAL_KEY)
  for (const key of storeKeysForSlot(record.targetSlot)) deleted.add(key)
  if (record.targetBeforeRaw != null) {
    set[canonicalStoreKey(record.targetSlot)] = record.targetBeforeRaw
    deleted.delete(canonicalStoreKey(record.targetSlot))
  }
  let manifest = null
  if (record.targetKind === 'new') {
    manifest = removeManifestEntry(parseManifest(get(manifestKey)), record.targetId)
    set[manifestKey] = serializeManifest(manifest)
    deleted.add(projectionKey(record.targetId))
  }
  for (const key of Object.keys(set)) deleted.delete(key)
  mutate({ set, delete: [...deleted] })
  return { ok: true, record, manifest }
}

function finishProjectTransfer({ get, mutate, transferId, manifestKey, projectionKey }) {
  const records = parseJournal(get(JOURNAL_KEY))
  const record = records.find((candidate) => candidate.transferId === transferId)
  if (!record || record.phase !== 'target_committed') return { ok: false }
  const remaining = records.filter((candidate) => candidate.transferId !== transferId)
  const set = {}
  const deleted = []
  if (remaining.length) set[JOURNAL_KEY] = serializeJournal(remaining)
  else deleted.push(JOURNAL_KEY)
  let manifest = null
  if (record.closeSource) {
    manifest = removeManifestEntry(parseManifest(get(manifestKey)), record.sourceId)
    set[manifestKey] = serializeManifest(manifest)
    deleted.push(...storeKeysForSlot(record.sourceSlot), projectionKey(record.sourceId))
  } else {
    const source = readWindowStore(get, record.sourceSlot)?.value ?? record.sourceBeforeRaw
    let sourceAfterRaw
    try { sourceAfterRaw = removeProjectFromStoreRaw(source, record.projectId, record.transferId) }
    catch { sourceAfterRaw = record.sourceAfterRaw }
    deleted.push(...storeKeysForSlot(record.sourceSlot))
    set[canonicalStoreKey(record.sourceSlot)] = sourceAfterRaw
  }
  for (const key of Object.keys(set)) {
    const index = deleted.indexOf(key)
    if (index >= 0) deleted.splice(index, 1)
  }
  mutate({ set, delete: [...new Set(deleted)] })
  return { ok: true, record, manifest }
}

/** Resolve every interrupted transfer before any renderer rehydrates. */
function recoverProjectTransfers({ get, mutate, manifestKey, projectionKey }) {
  const records = parseJournal(get(JOURNAL_KEY))
  if (!records.length) return { recovered: 0, manifest: null }
  const set = {}
  const deleted = new Set([JOURNAL_KEY])
  let manifest = parseManifest(get(manifestKey))
  let manifestChanged = false

  const valueForSlot = (slot, fallback) => {
    const canonical = canonicalStoreKey(slot)
    if (Object.prototype.hasOwnProperty.call(set, canonical)) return set[canonical]
    if (deleted.has(canonical)) return fallback
    return readWindowStore(get, slot)?.value ?? fallback
  }
  const writeSlot = (slot, raw) => {
    const keys = storeKeysForSlot(slot)
    for (const key of keys) deleted.add(key)
    if (raw != null) {
      set[keys[0]] = raw
      deleted.delete(keys[0])
    }
  }

  for (const record of records) {
    if (record.phase === 'prepared') {
      // Source remains authoritative until target adoption and its disk flush
      // have both been acknowledged. Restore the destination's exact preimage.
      writeSlot(record.targetSlot, record.targetBeforeRaw)
      if (record.targetKind === 'new') {
        manifest = removeManifestEntry(manifest, record.targetId)
        manifestChanged = true
        deleted.add(projectionKey(record.targetId))
      }
      continue
    }

    // Target is authoritative. Remove the source copy from its latest valid
    // snapshot, falling back to the prepared source preimage if needed.
    if (record.closeSource) {
      writeSlot(record.sourceSlot, null)
      manifest = removeManifestEntry(manifest, record.sourceId)
      manifestChanged = true
      deleted.add(projectionKey(record.sourceId))
    } else {
      const current = valueForSlot(record.sourceSlot, record.sourceBeforeRaw)
      let next
      try { next = removeProjectFromStoreRaw(current, record.projectId, record.transferId) }
      catch { next = record.sourceAfterRaw }
      writeSlot(record.sourceSlot, next)
    }
  }
  if (manifestChanged) set[manifestKey] = serializeManifest(manifest)
  for (const key of Object.keys(set)) deleted.delete(key)
  mutate({ set, delete: [...deleted] })
  return { recovered: records.length, manifest: manifestChanged ? manifest : null }
}

module.exports = {
  JOURNAL_KEY,
  JOURNAL_VERSION,
  abortProjectTransfer,
  canonicalStoreKey,
  finishProjectTransfer,
  markProjectTransferCommitted,
  parseJournal,
  prepareProjectTransfer,
  readWindowStore,
  recoverProjectTransfers,
  removeProjectFromStoreRaw,
  serializeJournal,
}
