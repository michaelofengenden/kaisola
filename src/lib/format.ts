/** Formatting helpers — dates, relative time, numbers. */

const RELATIVE_TIME_FORMAT = new Intl.RelativeTimeFormat('en', { numeric: 'auto' })
const COMPACT_NUMBER_FORMAT = new Intl.NumberFormat('en', { notation: 'compact', maximumFractionDigits: 1 })

export function relTime(iso: string, now = Date.now()): string {
  const t = new Date(iso).getTime()
  const diff = Math.round((t - now) / 1000)
  const abs = Math.abs(diff)
  const units: [number, Intl.RelativeTimeFormatUnit][] = [
    [60, 'second'],
    [3600, 'minute'],
    [86400, 'hour'],
    [604800, 'day'],
    [2629800, 'week'],
    [31557600, 'month'],
    [Infinity, 'year'],
  ]
  let prev = 1
  for (const [limit, unit] of units) {
    if (abs < limit) return RELATIVE_TIME_FORMAT.format(Math.round(diff / prev), unit)
    prev = limit
  }
  return iso
}

export function shortDate(iso: string): string {
  const d = new Date(iso)
  return d.toLocaleDateString('en', { month: 'short', day: 'numeric', year: 'numeric' })
}

export function clockTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('en', { hour: '2-digit', minute: '2-digit', hour12: false })
}

/** Compact elapsed duration: 42s · 3m 12s · 1h 04m. */
export function workedTime(ms: number): string {
  const s = Math.max(1, Math.round(ms / 1000))
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ${String(s % 60).padStart(2, '0')}s`
  return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, '0')}m`
}

export function compactNumber(n?: number): string {
  if (n == null) return '—'
  if (n < 1000) return String(n)
  return COMPACT_NUMBER_FORMAT.format(n)
}

export function authorList(authors: string[], max = 3): string {
  if (authors.length === 0) return 'Unknown'
  if (authors.length <= max) return authors.join(', ')
  return `${authors.slice(0, max).join(', ')} +${authors.length - max}`
}

/** Occurrences of `query` in `text`, case-insensitive (find-in-preview count).
 * Lives here (not DocumentPreview) so the count works without pulling the
 * lazy markdown-preview chunk into the main bundle. */
export function countMatches(text: string, query: string): number {
  const q = query.trim()
  if (!q) return 0
  const escaped = q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return text.match(new RegExp(escaped, 'gi'))?.length ?? 0
}
