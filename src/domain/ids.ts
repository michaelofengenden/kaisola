/** Tiny id helpers. Prefixed so ids are self-describing in logs and diffs. */

let counter = 0

export function uid(prefix = 'x'): string {
  counter += 1
  const rand = Math.random().toString(36).slice(2, 8)
  return `${prefix}_${rand}${counter.toString(36)}`
}

export function nowISO(): string {
  return new Date().toISOString()
}
