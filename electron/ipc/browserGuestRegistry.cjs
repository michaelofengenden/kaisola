/**
 * Ownership registry for embedded browser guests. React normally destroys a
 * <webview> when its card unmounts, but explicit main-process release closes
 * the renderer deterministically when a browser is hidden or closed.
 */
class BrowserGuestRegistry {
  constructor() {
    this.guests = new Map()
  }

  attach(owner, guest) {
    if (!owner || !guest || !Number.isInteger(guest.id)) return false
    this.guests.set(guest.id, { owner, guest })
    guest.once?.('destroyed', () => {
      const current = this.guests.get(guest.id)
      if (current?.guest === guest) this.guests.delete(guest.id)
    })
    return true
  }

  release(owner, guestId) {
    const record = this.guests.get(Number(guestId))
    if (!record || record.owner !== owner) return false
    this.guests.delete(Number(guestId))
    const guest = record.guest
    if (guest.isDestroyed?.()) return true
    try { if (guest.isDevToolsOpened?.()) guest.closeDevTools() } catch { /* best effort */ }
    try { guest.stop?.() } catch { /* best effort */ }
    try {
      guest.close?.()
      return true
    } catch {
      try { guest.destroy?.(); return true } catch { return false }
    }
  }

  releaseOwner(owner) {
    let released = 0
    for (const [guestId, record] of [...this.guests]) {
      if (record.owner === owner && this.release(owner, guestId)) released++
    }
    return released
  }

  count(owner) {
    return [...this.guests.values()].filter((record) => !owner || record.owner === owner).length
  }
}

module.exports = { BrowserGuestRegistry }
