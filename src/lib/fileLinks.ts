export interface LocalFileLink {
  path: string
  line?: number
}

const explicitExternalScheme = /^(?:https?|mailto|tel|ftp|data|javascript|kaisola):/i

const decode = (value: string) => {
  try { return decodeURIComponent(value) } catch { return value }
}

function normalizePosixPath(value: string) {
  const absolute = value.startsWith('/')
  const parts: string[] = []
  for (const part of value.split('/')) {
    if (!part || part === '.') continue
    if (part === '..') {
      if (!parts.length) return null
      parts.pop()
    } else {
      parts.push(part)
    }
  }
  return `${absolute ? '/' : ''}${parts.join('/')}` || (absolute ? '/' : '.')
}

/** Turn agent-authored Markdown links into a local file + optional line.
 * Web URLs stay external. Relative paths are rooted in the active workspace
 * and may not traverse above it; absolute paths are accepted because agents
 * also link to user config and files in adjacent worktrees. */
export function resolveLocalFileLink(href: string | undefined, workspacePath: string | null): LocalFileLink | null {
  let raw = decode(String(href || '').trim())
  if (!raw || raw.startsWith('#') || explicitExternalScheme.test(raw) || raw.startsWith('//')) return null

  if (/^file:/i.test(raw)) {
    try {
      const url = new URL(raw)
      if (url.hostname && url.hostname !== 'localhost') return null
      raw = decode(url.pathname)
    } catch {
      return null
    }
  }

  let line: number | undefined
  const hashAt = raw.lastIndexOf('#')
  if (hashAt >= 0) {
    const match = raw.slice(hashAt + 1).match(/^L?(\d+)(?::\d+)?$/i)
    if (match) line = Number(match[1])
    raw = raw.slice(0, hashAt)
  }
  const queryAt = raw.indexOf('?')
  if (queryAt >= 0) {
    const params = new URLSearchParams(raw.slice(queryAt + 1))
    const requestedLine = Number(params.get('line') || params.get('lineNumber'))
    if (!line && Number.isInteger(requestedLine) && requestedLine > 0) line = requestedLine
    raw = raw.slice(0, queryAt)
  }
  const suffix = raw.match(/:(\d+)(?::\d+)?$/)
  if (suffix) {
    line ??= Number(suffix[1])
    raw = raw.slice(0, -suffix[0].length)
  }
  if (!raw) return null

  const workspace = workspacePath ? normalizePosixPath(workspacePath) : null
  const absolute = raw.startsWith('/')
  const path = normalizePosixPath(absolute ? raw : workspace ? `${workspace}/${raw}` : raw)
  if (!path || (!absolute && !workspace)) return null
  if (!absolute && workspace && path !== workspace && !path.startsWith(`${workspace}/`)) return null

  return { path, ...(line && line > 0 ? { line } : {}) }
}
