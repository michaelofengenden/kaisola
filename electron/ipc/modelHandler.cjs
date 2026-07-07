// The live LLM seam. Pinned to claude-opus-4-8. The key lives in the main
// process (settingsHandler); the renderer only ever sends a request and receives
// streamed text. Implements a streaming call (model:stream → model:chunk:<id>
// events → resolves with the full text) and a blocking call (model:call).
const MODEL = 'claude-opus-4-8'
const API_URL = 'https://api.anthropic.com/v1/messages'
const API_VERSION = '2023-06-01'

const { getApiKey, getOpenaiKey } = require('./settingsHandler.cjs')

function send(sender, channel, payload) {
  if (sender && !sender.isDestroyed()) sender.send(channel, payload)
}

async function requestClaude({ system, messages, maxTokens, stream, model, tools, toolChoice }) {
  const key = getApiKey()
  if (!key) return { ok: false, noKey: true, message: 'No API key. Add one in Settings (⌘,).' }
  const res = await fetch(API_URL, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': key,
      'anthropic-version': API_VERSION,
    },
    body: JSON.stringify({
      model: model || MODEL,
      max_tokens: maxTokens ?? 2048,
      system,
      messages: messages ?? [],
      stream: !!stream,
      // structured-output seam: pass Anthropic tool-use through so an agent can
      // force a single tool call (e.g. emit_proposal) whose schema is a domain type
      ...(tools ? { tools } : {}),
      ...(toolChoice ? { tool_choice: toolChoice } : {}),
    }),
  })
  return res
}

// ── Anthropic (paid API) ─────────────────────────────────────────────────────
async function callAnthropic(req) {
  const res = await requestClaude({ ...req, stream: false })
  if (res.ok === false) return res // noKey passthrough
  if (!res.ok) return { ok: false, status: res.status, message: await res.text() }
  const data = await res.json()
  const blocks = data.content || []
  const text = blocks.filter((b) => b.type === 'text').map((b) => b.text).join('')
  const toolCalls = blocks.filter((b) => b.type === 'tool_use').map((b) => ({ id: b.id, name: b.name, input: b.input }))
  return { ok: true, model: req.model || MODEL, text, toolCalls, stopReason: data.stop_reason, usage: data.usage }
}

// Mirror of src/lib/extractJson.ts — keep the two in sync (ESM/CJS boundary prevents sharing).
// grab the first parseable {...} object from free text (for models that ignore tools)
function extractJsonObject(text) {
  const start = text.indexOf('{')
  if (start < 0) return null
  for (let end = text.lastIndexOf('}'); end > start; end = text.lastIndexOf('}', end - 1)) {
    try { return JSON.parse(text.slice(start, end + 1)) } catch { /* keep shrinking */ }
  }
  return null
}

// ── OpenAI-compatible (local Ollama / LM Studio / llama.cpp, or hosted) ──────
async function callOpenAI(req) {
  const baseUrl = (req.baseUrl || 'http://localhost:11434/v1').replace(/\/$/, '')
  // hosted OpenAI reads the key from the keychain (main only); local needs none
  const apiKey = req.apiKey || (req.useStoredKey ? getOpenaiKey() : undefined)
  if (req.useStoredKey && !apiKey) return { ok: false, noKey: true, message: 'No OpenAI API key. Add one in Settings (⌘,).' }
  const tools = req.tools
  // a JSON fallback hint so non-tool-calling local models still produce structured output
  const toolHint = tools && tools[0]
    ? `\n\nIf you cannot call tools, reply with ONLY a JSON object that is the arguments to ${tools[0].name} (no prose, no markdown fences).`
    : ''
  const body = {
    model: req.model || 'llama3.1',
    messages: [
      { role: 'system', content: (req.system || '') + toolHint },
      ...(req.messages || []),
    ],
    max_tokens: req.maxTokens ?? 2048,
    ...(tools ? { tools: tools.map((t) => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.input_schema } })) } : {}),
    ...(req.toolChoice && req.toolChoice.type === 'tool' ? { tool_choice: { type: 'function', function: { name: req.toolChoice.name } } } : {}),
  }
  let res
  try {
    res = await fetch(`${baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...(apiKey ? { authorization: `Bearer ${apiKey}` } : {}) },
      body: JSON.stringify(body),
    })
  } catch (e) {
    return { ok: false, unreachable: true, message: `Local model unreachable at ${baseUrl} — is it running? (${e.message})` }
  }
  if (!res.ok) return { ok: false, status: res.status, message: await res.text().catch(() => '') }
  const data = await res.json()
  const msg = (data.choices && data.choices[0] && data.choices[0].message) || {}
  const text = msg.content || ''
  let toolCalls = []
  if (Array.isArray(msg.tool_calls)) {
    toolCalls = msg.tool_calls.map((tc) => {
      let input = {}
      try { input = JSON.parse(tc.function && tc.function.arguments) } catch { /* leave {} */ }
      return { id: tc.id, name: tc.function && tc.function.name, input }
    })
  }
  if (toolCalls.length === 0 && tools && tools[0] && text) {
    const j = extractJsonObject(text)
    if (j) toolCalls = [{ name: tools[0].name, input: j }]
  }
  return { ok: true, model: req.model, text, toolCalls, usage: data.usage }
}

// ── OpenAI official SDK with strict structured outputs (json_schema) ─────────
let _OpenAI = null
function getOpenAI() {
  if (!_OpenAI) { const m = require('openai'); _OpenAI = m.OpenAI || m }
  return _OpenAI
}

// Uses response_format json_schema (strict) → the model is GUARANTEED to return
// schema-perfect JSON, no tool-calling guesswork. The key is read from the
// keychain in main; it never reaches the renderer.
async function callOpenAISDK(req) {
  const apiKey = req.apiKey || (req.useStoredKey ? getOpenaiKey() : undefined)
  if (req.useStoredKey && !apiKey) return { ok: false, noKey: true, message: 'No OpenAI API key. Add one in Settings (⌘,).' }
  const baseURL = (req.baseUrl || 'https://api.openai.com/v1').replace(/\/$/, '')
  let client
  try {
    const OpenAI = getOpenAI()
    client = new OpenAI({ apiKey: apiKey || 'unused', baseURL })
  } catch (e) {
    return { ok: false, message: `OpenAI SDK init failed: ${e.message}` }
  }
  try {
    const resp = await client.chat.completions.create({
      model: req.model || 'gpt-4o-mini',
      messages: [...(req.system ? [{ role: 'system', content: req.system }] : []), ...(req.messages || [])],
      response_format: { type: 'json_schema', json_schema: { name: req.responseSchema.name || 'emit_proposal', strict: true, schema: req.responseSchema.schema } },
      max_completion_tokens: req.maxTokens ?? 2048,
    })
    const msg = resp.choices && resp.choices[0] && resp.choices[0].message
    const text = (msg && msg.content) || ''
    let input = null
    try { input = JSON.parse(text) } catch { /* leave null */ }
    const toolCalls = input ? [{ name: req.responseSchema.name || 'emit_proposal', input }] : []
    return { ok: true, model: req.model, text, toolCalls, usage: resp.usage }
  } catch (e) {
    return { ok: false, status: e && e.status, message: String((e && e.message) || e) }
  }
}

function registerModelHandlers(ipcMain) {
  // Blocking call — dispatches to the chosen provider. Default is OpenAI (cheap,
  // strict structured output via the SDK); local/agent are free, Anthropic is paid.
  ipcMain.handle('model:call', async (_e, req = {}) => {
    try {
      if (req.provider === 'anthropic') return await callAnthropic(req)
      if (req.provider === 'openai' && req.responseSchema) return await callOpenAISDK(req)
      return await callOpenAI(req)
    } catch (err) {
      return { ok: false, message: String(err.message || err) }
    }
  })

  // Streaming call — emits model:chunk:<id> as text arrives, resolves when done.
  ipcMain.handle('model:stream', async (event, { id, ...req } = {}) => {
    const sender = event.sender
    const chan = `model:chunk:${id}`
    try {
      const res = await requestClaude({ ...req, stream: true })
      if (res.ok === false) {
        send(sender, chan, { done: true, error: res.message, noKey: res.noKey })
        return res
      }
      if (!res.ok) {
        const msg = await res.text()
        send(sender, chan, { done: true, error: msg })
        return { ok: false, message: msg }
      }
      // parse the SSE stream
      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''
      let full = ''
      for (;;) {
        const { value, done } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        const events = buffer.split('\n\n')
        buffer = events.pop() || ''
        for (const ev of events) {
          const line = ev.split('\n').find((l) => l.startsWith('data:'))
          if (!line) continue
          try {
            const json = JSON.parse(line.slice(5).trim())
            if (json.type === 'content_block_delta' && json.delta && json.delta.text) {
              full += json.delta.text
              send(sender, chan, { text: json.delta.text })
            }
          } catch {
            /* ignore keep-alives / non-JSON */
          }
        }
      }
      send(sender, chan, { done: true })
      return { ok: true, model: MODEL, text: full }
    } catch (err) {
      send(sender, chan, { done: true, error: String(err.message || err) })
      return { ok: false, message: String(err.message || err) }
    }
  })
}

module.exports = { registerModelHandlers, MODEL }
