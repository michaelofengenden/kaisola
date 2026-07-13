const SAFE_NONCE = /[^A-Za-z0-9_-]/g

const cleanNonce = (value: string): string => value.replace(SAFE_NONCE, '').slice(0, 96)

/** A collision-resistant id shared by every checkout in one Mesh execution. */
export function newMeshWorktreeBatchId(
  now = Date.now(),
  nonce = globalThis.crypto?.randomUUID?.() ?? `${Math.random().toString(36).slice(2)}${Math.random().toString(36).slice(2)}`,
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
