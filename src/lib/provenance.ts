import type { Project, ProvenanceLink, Paper } from '../domain/types'

export interface ResolvedProvenance {
  kind: ProvenanceLink['kind']
  /** Icon + label for the chip. */
  icon: string
  label: string
  detail?: string
  /** True if this link is externally verifiable and verified. */
  verified?: boolean
  /** Deep-link target inside the app, e.g. {stage,id}. */
  href?: { stage: string; id: string }
}

/** Turn a raw provenance link into something the popover can render. */
export function resolveProvenance(link: ProvenanceLink, project: Project): ResolvedProvenance {
  switch (link.kind) {
    case 'citation': {
      const paper = project.corpus.find((s) => s.id === link.sourceId) as Paper | undefined
      return {
        kind: 'citation',
        icon: 'Quote',
        label: paper ? paper.title : 'Cited source',
        detail: link.quote ? `“${link.quote}”${link.locator ? ` — ${link.locator}` : ''}` : link.locator,
        verified: link.verified,
        href: paper ? { stage: 'corpus', id: paper.id } : undefined,
      }
    }
    case 'result': {
      const run = project.runs.find((r) => r.id === link.runId)
      return {
        kind: 'result',
        icon: 'FlaskConical',
        label: run ? run.label : 'Experiment result',
        detail: link.summary,
        verified: true,
        href: { stage: 'analysis', id: link.resultId },
      }
    }
    case 'derivation':
      return { kind: 'derivation', icon: 'Sigma', label: 'Derivation', detail: link.text }
    case 'dataset': {
      const ds = project.corpus.find((s) => s.id === link.sourceId)
      return { kind: 'dataset', icon: 'Database', label: ds?.title ?? 'Dataset', detail: link.license }
    }
    case 'note':
      return {
        kind: 'note',
        icon: 'StickyNote',
        label: link.author ? `Note · ${link.author}` : 'Human note',
        detail: link.text,
      }
  }
}
