/**
 * Idea mode: a bounded group discussion over the same private Mesh sessions,
 * with none of Build mode's repository machinery. Each user message mints one
 * cycle: every member answers the prompt concurrently without peer content,
 * then — after all initial responses settle — exactly one concurrent reaction
 * pass runs, where each member sees the original message and every peer's
 * initial response. Nothing here creates worktrees, edits files, or merges.
 */

export type IdeaMessageKind = 'user' | 'initial' | 'reaction'

export interface IdeaMessage {
  /** Stable identity: one user message per cycle, at most one initial and one
   * reaction per member per cycle — re-appends merge instead of duplicating. */
  id: string
  cycleId: string
  kind: IdeaMessageKind
  /** 'user' or the authoring member's threadId. */
  authorId: string
  label: string
  text: string
  at: number
}

/** The durable transcript stays bounded; prompts are bounded separately. */
export const MAX_IDEA_MESSAGES = 400
const MAX_IDEA_PROMPT_TEXT = 28_000

export const ideaMessageId = (cycleId: string, kind: IdeaMessageKind, authorId: string): string =>
  kind === 'user' ? `${cycleId}:user` : `${cycleId}:${kind}:${authorId}`

/** Idempotent ordered merge: a known id updates in place (a pause snapshot
 * followed by the stage settling must never duplicate a message); fresh
 * entries append in the order given, which is completion order. */
export function mergeIdeaMessages(
  transcript: readonly IdeaMessage[],
  entries: readonly IdeaMessage[],
): IdeaMessage[] {
  const merged = [...transcript]
  for (const entry of entries) {
    const index = merged.findIndex((message) => message.id === entry.id)
    if (index >= 0) merged[index] = { ...merged[index], ...entry }
    else merged.push(entry)
  }
  return merged.slice(-MAX_IDEA_MESSAGES)
}

/** Messages this member has neither authored nor been shown. `seen` holds the
 * transcript length recorded at the member's previous prompt dispatch, so a
 * new cycle forwards exactly the peer messages that arrived since. */
export function unseenIdeaMessages(
  transcript: readonly IdeaMessage[],
  seen: Record<string, number> | undefined,
  memberThreadId: string,
): IdeaMessage[] {
  return transcript
    .slice(Math.max(0, seen?.[memberThreadId] ?? 0))
    .filter((message) => message.authorId !== memberThreadId)
}

const packet = (messages: readonly IdeaMessage[]): string =>
  messages.map((message) => `${message.label}:\n${message.text}`).join('\n\n---\n\n').slice(-MAX_IDEA_PROMPT_TEXT)

/** The concurrent first pass. Deliberately carries no peer content from this
 * cycle — only the new user message plus whatever earlier-cycle messages the
 * member has not yet seen. */
export function ideaInitialPrompt(
  memberLabel: string,
  peerLabels: readonly string[],
  unseen: readonly IdeaMessage[],
): string {
  return `You are ${memberLabel} in a group idea chat with ${peerLabels.join(' and ')}. Discussion only: do not edit files, run commands, or change any state. Give your own take first — reactions come after everyone answers. Be concise and conversational.\n\nNew messages:\n${packet(unseen)}`
}

/** The single reaction pass: the original user message plus every peer's
 * initial response from this cycle. */
export function ideaReactionPrompt(
  memberLabel: string,
  userText: string,
  peerInitials: readonly IdeaMessage[],
): string {
  return `You are ${memberLabel}. Everyone has answered. React once to the group: build on, challenge, or connect the responses below. Keep it short and specific. Discussion only: do not edit files, run commands, or change any state.\n\nOriginal message:\n${userText.slice(-MAX_IDEA_PROMPT_TEXT)}\n\nPeer responses:\n${packet(peerInitials)}`
}
