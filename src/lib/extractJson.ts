/** Pull the first parseable {...} object out of free text (for the agent route). */
export function extractJsonObject(text: string): unknown | null {
  const start = text.indexOf('{')
  if (start < 0) return null
  for (let end = text.lastIndexOf('}'); end > start; end = text.lastIndexOf('}', end - 1)) {
    try { return JSON.parse(text.slice(start, end + 1)) } catch { /* keep shrinking */ }
  }
  return null
}
