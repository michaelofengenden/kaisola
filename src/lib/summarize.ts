import { useKaisola } from '../store/store'
import { bridge } from './bridge'

/**
 * One-shot "explain this" through whatever reasoning provider Settings points
 * at (codex subscription / OpenAI / local model / Anthropic) — the same
 * routing the research agents use, so it costs what the user chose to pay
 * (usually nothing). Returns null when no provider can answer; callers show
 * their deterministic fallback instead of an error.
 */
export async function summarizeWithModel(prompt: string): Promise<string | null> {
  const s = useKaisola.getState()
  try {
    if (s.reasoningProvider === 'codex') {
      const r = await bridge.codex.exec({ prompt, cwd: s.workspacePath ?? undefined })
      return r.ok && r.text?.trim() ? r.text.trim() : null
    }
    const req =
      s.reasoningProvider === 'openai'
        ? { provider: 'openai' as const, baseUrl: s.openaiBaseUrl, model: s.openaiModel, useStoredKey: true }
        : s.reasoningProvider === 'local'
          ? { provider: 'openai' as const, baseUrl: s.localBaseUrl, model: s.localModel }
          : s.reasoningProvider === 'anthropic'
            ? { provider: 'anthropic' as const, model: s.claudeModel }
            : null
    if (!req) return null // 'agent' shares a chat session — not a quiet one-shot
    const r = await bridge.model.call({ ...req, maxTokens: 400, messages: [{ role: 'user', content: prompt }] })
    return r.ok && r.text?.trim() ? r.text.trim() : null
  } catch {
    return null
  }
}
