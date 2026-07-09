/**
 * Claude API list prices, USD per MILLION tokens — the $ chip's rate table.
 * Source: platform.claude.com/docs/en/about-claude/pricing (checked 2026-07-09).
 * Cache-write uses the 5-minute rate (1.25× input) — transcripts don't say
 * which duration was used and 5m is the default. Unknown models price as null
 * and the chip shows raw tokens instead of a made-up number.
 * NOTE: sonnet-5 carries INTRO pricing through 2026-08-31 ($2/$10); bump to
 * $3/$15 when that lapses.
 */
export interface Rate { input: number; output: number; cacheRead: number; cacheWrite: number }

const TABLE: Array<{ re: RegExp; rate: Rate }> = [
  { re: /fable|mythos/i, rate: { input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5 } },
  { re: /opus-4-[5-9]/i, rate: { input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25 } },
  { re: /opus/i, rate: { input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75 } },
  { re: /sonnet-5/i, rate: { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5 } },
  { re: /sonnet/i, rate: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 } },
  { re: /haiku-4/i, rate: { input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25 } },
  { re: /haiku/i, rate: { input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1 } },
]

export const rateFor = (model: string): Rate | null =>
  TABLE.find((t) => t.re.test(model))?.rate ?? null

export interface ModelSums { model: string; input: number; output: number; cacheRead: number; cacheWrite: number }

/** Total estimated USD; `known` false when any model had no rate. */
export function estimate(models: ModelSums[]): { usd: number; known: boolean; tokens: number } {
  let usd = 0
  let known = true
  let tokens = 0
  for (const m of models) {
    tokens += m.input + m.output + m.cacheRead + m.cacheWrite
    const r = rateFor(m.model)
    if (!r) { known = false; continue }
    usd += (m.input * r.input + m.output * r.output + m.cacheRead * r.cacheRead + m.cacheWrite * r.cacheWrite) / 1_000_000
  }
  return { usd, known, tokens }
}

export const fmtUsd = (v: number): string => (v >= 10 ? `$${v.toFixed(0)}` : v >= 1 ? `$${v.toFixed(2)}` : `$${v.toFixed(2)}`)
export const fmtTok = (n: number): string => (n >= 1_000_000 ? `${(n / 1_000_000).toFixed(1)}M` : n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n))
