'use strict'

/** Detach one authenticated terminal owner without broadening the request to
 * the other projects or terminals held by the same renderer identity. */
function terminalDetachOwnerRoute({ manager, params = {}, owner, requireAllowed }) {
  // Keep the request identity exact. Truncating an overlong id here could
  // detach an unrelated terminal whose real id equals the truncated prefix.
  const id = String(params.id || '')
  // Authorization must precede both existence disclosure and ownership change.
  requireAllowed(id)
  return {
    id,
    ok: true,
    detached: manager.detachSender(owner, id),
  }
}

module.exports = { terminalDetachOwnerRoute }
