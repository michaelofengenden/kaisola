// GROBID PDF → TEI (with sentence coordinates). Runs in the main process: it
// downloads the PDF and POSTs it to a GROBID REST service. Returns the raw TEI
// XML for the renderer (src/lib/grobid.ts) to parse. Graceful: any miss resolves
// { ok:false, message } — never throws to the renderer. GROBID is opt-in via a
// user-configured endpoint (Settings), so this is dormant until one is set.

const GROBID_TIMEOUT_MS = 120_000

async function processPdf({ pdfUrl, endpoint } = {}) {
  if (!endpoint) return { ok: false, message: 'No GROBID endpoint set (Settings → Literature sources).' }
  if (!pdfUrl) return { ok: false, message: 'No PDF URL for this paper.' }
  // abort both fetches if GROBID is slow — a hung endpoint would stall ingest forever
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), GROBID_TIMEOUT_MS)
  try {
    const pdfRes = await fetch(pdfUrl, { signal: controller.signal })
    if (!pdfRes.ok) return { ok: false, message: `Could not download the PDF (${pdfRes.status}).` }
    const buf = Buffer.from(await pdfRes.arrayBuffer())
    const form = new FormData()
    form.append('input', new Blob([buf], { type: 'application/pdf' }), 'paper.pdf')
    form.append('teiCoordinates', 's')
    form.append('consolidateHeader', '1')
    const url = `${endpoint.replace(/\/$/, '')}/api/processFulltextDocument`
    const res = await fetch(url, { method: 'POST', body: form, signal: controller.signal })
    if (!res.ok) return { ok: false, message: `GROBID returned ${res.status}.` }
    const tei = await res.text()
    return { ok: true, tei }
  } catch (err) {
    if (err && err.name === 'AbortError') return { ok: false, message: 'GROBID request timed out.' }
    return { ok: false, message: String((err && err.message) || err) }
  } finally {
    clearTimeout(timer)
  }
}

function registerGrobidHandlers(ipcMain) {
  ipcMain.handle('grobid:process', (_e, req = {}) => processPdf(req))
}

module.exports = { registerGrobidHandlers }
