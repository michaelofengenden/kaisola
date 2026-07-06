/** Formatting helpers — dates, relative time, numbers. */

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
  const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' })
  let prev = 1
  for (const [limit, unit] of units) {
    if (abs < limit) return rtf.format(Math.round(diff / prev), unit)
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

export function compactNumber(n?: number): string {
  if (n == null) return '—'
  if (n < 1000) return String(n)
  return new Intl.NumberFormat('en', { notation: 'compact', maximumFractionDigits: 1 }).format(n)
}

export function authorList(authors: string[], max = 3): string {
  if (authors.length === 0) return 'Unknown'
  if (authors.length <= max) return authors.join(', ')
  return `${authors.slice(0, max).join(', ')} +${authors.length - max}`
}
