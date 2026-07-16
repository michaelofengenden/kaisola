const test = require('node:test')
const assert = require('node:assert/strict')

const msg = (cycleId, kind, authorId, text, at) => ({
  id: kind === 'user' ? `${cycleId}:user` : `${cycleId}:${kind}:${authorId}`,
  cycleId,
  kind,
  authorId,
  label: authorId === 'user' ? 'You' : authorId,
  text,
  at,
})

test('Idea transcript merge is idempotent and ordered by completion', async () => {
  const { mergeIdeaMessages, ideaMessageId, MAX_IDEA_MESSAGES } = await import('../src/lib/ideaCycle.ts')
  assert.equal(ideaMessageId('c1', 'user', 'user'), 'c1:user')
  assert.equal(ideaMessageId('c1', 'initial', 'a'), 'c1:initial:a')

  const base = mergeIdeaMessages([], [msg('c1', 'user', 'user', 'idea?', 1)])
  const withInitials = mergeIdeaMessages(base, [
    msg('c1', 'initial', 'claude', 'fast take', 2),
    msg('c1', 'initial', 'codex', 'slow take', 3),
  ])
  assert.deepEqual(withInitials.map((m) => m.id), ['c1:user', 'c1:initial:claude', 'c1:initial:codex'])

  // A pause snapshot already appended claude's initial; the stage settling
  // must update in place, never duplicate — and must not reorder.
  const again = mergeIdeaMessages(withInitials, [
    msg('c1', 'initial', 'claude', 'fast take (final)', 2),
    msg('c1', 'reaction', 'codex', 'building on it', 4),
  ])
  assert.deepEqual(again.map((m) => m.id), ['c1:user', 'c1:initial:claude', 'c1:initial:codex', 'c1:reaction:codex'])
  assert.equal(again[1].text, 'fast take (final)')

  // The durable transcript stays bounded.
  const flood = Array.from({ length: MAX_IDEA_MESSAGES + 20 }, (_, i) => msg(`c${i}`, 'user', 'user', `m${i}`, i))
  assert.equal(mergeIdeaMessages([], flood).length, MAX_IDEA_MESSAGES)
})

test('Per-member stable cursor forwards exactly the unseen peer messages', async () => {
  const { ideaSeenCursor, mergeIdeaMessages, unseenIdeaMessages } = await import('../src/lib/ideaCycle.ts')
  // Cycle 1: user message, both initials, both reactions.
  const cycle1 = mergeIdeaMessages([], [
    msg('c1', 'user', 'user', 'first idea', 1),
    msg('c1', 'initial', 'claude', 'claude initial', 2),
    msg('c1', 'initial', 'codex', 'codex initial', 3),
    msg('c1', 'reaction', 'claude', 'claude reaction', 4),
    msg('c1', 'reaction', 'codex', 'codex reaction', 5),
  ])
  // Reaction prompts were dispatched when the transcript held 3 entries
  // (user + both initials); reactions landed after.
  const seen = { claude: ideaSeenCursor(cycle1.slice(0, 3)), codex: ideaSeenCursor(cycle1.slice(0, 3)) }
  const cycle2 = mergeIdeaMessages(cycle1, [msg('c2', 'user', 'user', 'second idea', 6)])
  const claudeUnseen = unseenIdeaMessages(cycle2, seen, 'claude')
  // Claude never saw codex's reaction; its own reaction is excluded.
  assert.deepEqual(claudeUnseen.map((m) => m.id), ['c1:reaction:codex', 'c2:user'])
  const codexUnseen = unseenIdeaMessages(cycle2, seen, 'codex')
  assert.deepEqual(codexUnseen.map((m) => m.id), ['c1:reaction:claude', 'c2:user'])
  // A missing seen record forwards everything not self-authored.
  assert.equal(unseenIdeaMessages(cycle2, undefined, 'claude').length, 4)
})

test('Stable cursors do not lose a message when the transcript trims at 400', async () => {
  const { ideaSeenCursor, MAX_IDEA_MESSAGES, mergeIdeaMessages, unseenIdeaMessages } = await import('../src/lib/ideaCycle.ts')
  const full = mergeIdeaMessages([], Array.from({ length: MAX_IDEA_MESSAGES }, (_, i) => msg(`c${i}`, 'user', 'user', `m${i}`, i)))
  const seen = { claude: ideaSeenCursor(full) }
  const next = mergeIdeaMessages(full, [msg('fresh', 'user', 'user', 'must survive rollover', MAX_IDEA_MESSAGES + 1)])
  assert.equal(next.length, MAX_IDEA_MESSAGES)
  assert.deepEqual(unseenIdeaMessages(next, seen, 'claude').map((message) => message.id), ['fresh:user'])

  // Legacy length cursors at the cap fail open and migrate safely instead of
  // returning an empty slice that hides the fresh message.
  const legacy = unseenIdeaMessages(next, { claude: MAX_IDEA_MESSAGES }, 'claude')
  assert.equal(legacy.at(-1)?.id, 'fresh:user')
})

test('Idea prompts carry the right context and nothing more', async () => {
  const { ideaInitialPrompt, ideaReactionPrompt } = await import('../src/lib/ideaCycle.ts')
  const initial = ideaInitialPrompt('Claude', ['Codex'], [msg('c1', 'user', 'user', 'What about a plugin bazaar?', 1)])
  assert.match(initial, /group idea chat with Codex/)
  assert.match(initial, /What about a plugin bazaar\?/)
  assert.match(initial, /do not edit files/i)
  // The concurrent first pass never includes peer content from this cycle.
  assert.doesNotMatch(initial, /Codex:\n/)

  const reaction = ideaReactionPrompt('Codex', 'What about a plugin bazaar?', [
    msg('c1', 'initial', 'Claude', 'Claude thinks distribution is the hard part', 2),
  ])
  assert.match(reaction, /React once to the group/)
  assert.match(reaction, /What about a plugin bazaar\?/)
  assert.match(reaction, /Claude:\nClaude thinks distribution is the hard part/)
})
