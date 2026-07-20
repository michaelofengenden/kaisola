'use strict'

const os = require('node:os')

const MAX_RESPONSE_BYTES = 64 * 1024

function companionRendezvousUrl(serverUrl) {
  let url
  try { url = new URL(serverUrl) } catch { return null }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password) return null
  const segments = url.pathname.split('/').filter(Boolean)
  if (segments.at(-1) === 'session') segments[segments.length - 1] = 'companionRendezvous'
  else segments.push('companionRendezvous')
  url.pathname = `/${segments.join('/')}`
  url.search = ''
  url.hash = ''
  return url.toString()
}

function desktopDisplayName(hostname = os.hostname()) {
  const clean = String(hostname || '').replace(/\.local$/i, '').replace(/[\0-\x1f\x7f]/g, '').trim().slice(0, 72)
  return clean ? `${clean} Mac` : 'Kaisola Mac'
}

class CompanionAccountRendezvous {
  constructor({
    tokenProvider,
    configProvider,
    fetchImpl = globalThis.fetch,
    timeoutMs = 5_000,
    nameProvider = desktopDisplayName,
  } = {}) {
    if (typeof tokenProvider !== 'function' || typeof configProvider !== 'function' || typeof fetchImpl !== 'function') {
      throw new Error('companion account rendezvous dependencies are invalid')
    }
    this.tokenProvider = tokenProvider
    this.configProvider = configProvider
    this.fetchImpl = fetchImpl
    this.timeoutMs = Math.max(500, Math.min(Number(timeoutMs) || 5_000, 15_000))
    this.nameProvider = nameProvider
  }

  async publishOffer(payload) {
    const result = await this.#request({
      action: 'publish',
      offer: { payload, desktopName: this.nameProvider() },
    })
    return result?.ok === true
  }

  async withdrawOffer(pairingNonce) {
    const result = await this.#request({ action: 'withdraw', pairingNonce })
    return result?.ok === true
  }

  async #request(body) {
    const endpoint = companionRendezvousUrl(this.configProvider()?.serverUrl)
    if (!endpoint) return null
    let token
    try { token = await this.tokenProvider() } catch { return null }
    if (typeof token !== 'string' || token.length < 20 || token.length > 20_000) return null

    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), this.timeoutMs)
    timer.unref?.()
    try {
      const response = await this.fetchImpl(endpoint, {
        method: 'POST',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify(body),
        signal: controller.signal,
      })
      const text = await response.text()
      if (!response.ok || Buffer.byteLength(text, 'utf8') > MAX_RESPONSE_BYTES) return null
      const decoded = JSON.parse(text)
      return decoded && typeof decoded === 'object' ? decoded : null
    } catch {
      return null
    } finally {
      clearTimeout(timer)
    }
  }
}

module.exports = {
  CompanionAccountRendezvous,
  companionRendezvousUrl,
  desktopDisplayName,
}
