/**
 * Client-side permission rules (OpenCode's model, simplified): flat
 * `{action, resource}` allow-rules with `*` wildcards, persisted per
 * workspace. The agent keeps asking (we always answer allow_once, never
 * allow_always), so these rules stay the single source of truth — visible
 * and deletable in Settings, uniform across agents and sessions.
 */
import type { AcpPermissionRequest } from './bridge'

export interface PermissionRule {
  id: string
  workspace: string
  /** ACP tool-call kind: execute / edit / read / delete / fetch / other… */
  action: string
  /** wildcard pattern over the request title (commands) — '*' = any */
  resource: string
  at: string
}

/** `*`-only glob, ported from OpenCode's ~10-line matcher. Case-insensitive. */
export function wildcardMatch(pattern: string, value: string): boolean {
  const rx = new RegExp(
    '^' + pattern.split('*').map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$',
    'is',
  )
  return rx.test(value)
}

const reqAction = (req: Pick<AcpPermissionRequest, 'kind'>) => req.kind || 'other'

/** Derive the rule a click on "Always allow" should create. Commands get
 * `firstWord *` (allow the tool, not one exact invocation); everything else
 * allows the whole kind. Deterministic and predictable beats clever. */
export function ruleForRequest(req: Pick<AcpPermissionRequest, 'kind' | 'title'>): { action: string; resource: string } {
  const action = reqAction(req)
  if (action === 'execute') {
    const first = (req.title || '').trim().split(/\s+/)[0]
    return { action, resource: first ? `${first} *` : '*' }
  }
  return { action, resource: '*' }
}

/** Human label for a rule (buttons, Settings rows, toasts). */
export function ruleLabel(rule: { action: string; resource: string }): string {
  return rule.resource === '*' ? `all ${rule.action}` : rule.resource.replace(/ \*$/, ' …')
}

/** Does any rule cover this request? (allow-only rules → any match allows.) */
export function requestMatchesRules(
  rules: PermissionRule[],
  workspace: string | null,
  req: Pick<AcpPermissionRequest, 'kind' | 'title'>,
): PermissionRule | undefined {
  if (!workspace) return undefined
  const action = reqAction(req)
  return rules.find(
    (r) => r.workspace === workspace && r.action === action && wildcardMatch(r.resource, req.title || ''),
  )
}

/** The allow_once-shaped answer for a request (never allow_always — rules own persistence). */
export function allowOnceAnswer(req: AcpPermissionRequest): { optionId?: string; decision?: 'allow' } {
  const opt = req.options.find((o) => o.kind === 'allow_once') ?? req.options[0]
  return opt ? { optionId: opt.optionId } : { decision: 'allow' }
}

/** The reject_once-shaped answer. */
export function rejectOnceAnswer(req: AcpPermissionRequest): { optionId?: string; decision?: 'reject' } {
  const opt = req.options.find((o) => o.kind === 'reject_once')
  return opt ? { optionId: opt.optionId } : { decision: 'reject' }
}

/** Does a path (or command line mentioning one) hit a sensitive glob?
 * `**​/x` patterns also match root-level `x` (no slash). */
export function pathIsSensitive(globs: string[], pathish: string): boolean {
  if (!pathish) return false
  return globs.some(
    (g) =>
      wildcardMatch(g, pathish) ||
      (g.startsWith('**/') && wildcardMatch(g.slice(3), pathish)) ||
      (g.startsWith('**/') && wildcardMatch(`*${g.slice(2)}`, pathish)),
  )
}

/** A permission request touching sensitive files (title text or diff paths). */
export function requestIsSensitive(
  globs: string[],
  req: Pick<AcpPermissionRequest, 'title' | 'diffs' | 'sensitive'>,
): boolean {
  if (req.sensitive) return true
  if ((req.diffs ?? []).some((d) => pathIsSensitive(globs, d.path))) return true
  // commands name their targets in the title — scan its tokens
  return (req.title || '')
    .split(/\s+/)
    .some((tok) => pathIsSensitive(globs, tok.replace(/^['"]|['"]$/g, '')))
}
