export const MAX_USER_QUEUED_PROMPTS = 20
export const MAX_PERSISTED_QUEUED_PROMPTS = MAX_USER_QUEUED_PROMPTS + 1

/** Normal user input is rejected at the visible cap. One extra slot is
 * reserved exclusively for restoring an already-accepted failed/preflight
 * prompt, so preservation never evicts a different user message. */
export function addQueuedPrompt<T>(
  current: readonly T[],
  prompt: T,
  options: { front?: boolean; preserveAccepted?: boolean } = {},
): T[] | null {
  const limit = options.preserveAccepted ? MAX_PERSISTED_QUEUED_PROMPTS : MAX_USER_QUEUED_PROMPTS
  if (current.length >= limit) return null
  return options.front ? [prompt, ...current] : [...current, prompt]
}
