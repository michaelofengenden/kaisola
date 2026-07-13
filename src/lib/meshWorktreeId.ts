const SAFE_NONCE = /[^A-Za-z0-9_-]/g

const cleanNonce = (value: string): string => value.replace(SAFE_NONCE, '').slice(0, 96)

const secureNonce = (): string => {
  const cryptoApi = globalThis.crypto
  if (!cryptoApi) throw new Error('Secure random generation is unavailable.')
  if (cryptoApi.randomUUID) return cryptoApi.randomUUID()
  const bytes = new Uint8Array(16)
  cryptoApi.getRandomValues(bytes)
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
}

/** A collision-resistant id shared by every checkout in one Mesh execution. */
export function newMeshWorktreeBatchId(
  now = Date.now(),
  nonce = secureNonce(),
): string {
  const safe = cleanNonce(nonce)
  if (!safe) throw new Error('Mesh worktree nonce is empty.')
  return `${Math.max(0, Math.floor(now)).toString(36)}-${safe}`
}

export function meshWorktreeTaskId(batchId: string, memberIndex: number): string {
  const safeBatch = cleanNonce(batchId)
  if (!safeBatch || !Number.isSafeInteger(memberIndex) || memberIndex < 0) {
    throw new Error('Invalid Mesh worktree task id input.')
  }
  return `group-${safeBatch}-${memberIndex}`
}
