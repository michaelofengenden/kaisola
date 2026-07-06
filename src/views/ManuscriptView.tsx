import { useKaisola } from '../store/store'
import { ViewHeader } from '../components/ViewHeader'
import { TrustBadge } from '../components/TrustBadge'
import { ProvenanceChip } from '../components/Provenance'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { sectionTrust, minTrust, TRUST_LABEL } from '../domain/trust'
import { lintProvenanced, lintSeverity } from '../lib/lint'
import { shortDate } from '../lib/format'
import type { TrustLevel } from '../domain/types'

/**
 * The manuscript stage — artifact-grounded writing. Every section shows its
 * trust (the weakest of its claims), and every claim is one click from its
 * evidence. Unsupported claims are flagged inline: the editor's job is to make
 * the opinionated rule visible — every claim links to a citation, result,
 * derivation, dataset, or note.
 */
export function ManuscriptView() {
  const ms = useKaisola((s) => s.project.manuscript)
  const verifyCitations = useKaisola((s) => s.verifyCitations)
  const overall = minTrust(ms.sections.map(sectionTrust))
  const allClaims = ms.sections.flatMap((s) => s.claims)
  const unsupported = allClaims.filter((c) => c.trust === 'unsupported' && !c.speculative).length
  const unverified = allClaims.filter((c) => c.provenance.some((p) => p.kind === 'citation' && !p.verified)).length

  const scrollTo = (id: string) => document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' })

  if (ms.sections.length === 0) {
    return (
      <div className="view">
        <ViewHeader icon="FileText" title="Manuscript" sub="Artifact-grounded draft" />
        <EmptyState
          icon="FileText"
          title="Nothing drafted yet"
          hint="The writing agent drafts sections from your results — every claim links to a citation, a result, or a note."
        />
      </div>
    )
  }

  return (
    <div className="view">
      <ViewHeader icon="FileText" title="Manuscript" sub={`Updated ${shortDate(ms.updatedAt)} · artifact-grounded draft`}>
        <span className={`trust trust-${overall}`}>
          <Icon name="ShieldCheck" size={12} /> Trust: {TRUST_LABEL[overall]}
        </span>
        {unsupported > 0 && (
          <span className="badge" style={{ color: 'var(--trust-unsupported)' }}>
            <Icon name="AlertTriangle" size={12} /> {unsupported} unsupported
          </span>
        )}
        {unverified > 0 && (
          <button className="btn btn-sm" onClick={() => { void verifyCitations() }} title="Check each cited quote actually supports its claim">
            <Icon name="BadgeAlert" size={13} style={{ color: 'var(--warn)' }} /> {unverified} unverified · Verify
          </button>
        )}
        <button className="btn btn-sm"><Icon name="Download" size={13} /> Export</button>
      </ViewHeader>

      <div className="ms">
        <nav className="ms-toc">
          <div className="ms-toc-title">Contents</div>
          {ms.sections.map((s) => {
            const t = sectionTrust(s)
            return (
              <button key={s.id} className="ms-toc-item" onClick={() => scrollTo(s.id)}>
                <span className={`trust trust-${t}`} style={{ padding: 0, width: 7, height: 7 }} title={`Trust: ${TRUST_LABEL[t]}`} />
                <span className="grow truncate">{s.heading}</span>
              </button>
            )
          })}
          <div className="hr" style={{ margin: 'var(--sp-4) 0' }} />
          <p className="faint" style={{ fontSize: 'var(--fs-11)', lineHeight: 'var(--lh-snug)' }}>
            A section's trust is the weakest of its claims. One unsupported claim taints the section.
          </p>
        </nav>

        <div className="ms-doc">
          <article className="ms-paper">
            <h1 className="ms-h1">{ms.title}</h1>

            {ms.sections.map((s) => {
              const t = sectionTrust(s)
              return (
                <section key={s.id} id={s.id} className="ms-section">
                  <div className="ms-section-head">
                    <h2 className="grow">{s.heading}</h2>
                    <TrustBadge trust={t} />
                  </div>
                  <p className="ms-body">{s.body}</p>

                  {s.claims.length > 0 && (
                    <div className="ms-claims">
                      <div className="ms-claims-title">Claims in this section · {s.claims.length}</div>
                      {s.claims.map((c) => {
                        const ct: TrustLevel = c.speculative ? 'medium' : c.trust
                        const issues = lintProvenanced(c)
                        const sev = lintSeverity(issues)
                        return (
                          <div key={c.id} className={`ms-claim is-${ct}`}>
                            <div className="grow">
                              <span className={`claim-text${sev ? ` lint-${sev}` : ''}`}>{c.text}</span>
                              {issues.map((iss, i) => (
                                <div key={i} className={`claim-flag is-${iss.kind}`}>
                                  <Icon name={iss.kind === 'unsupported' ? 'AlertTriangle' : 'BadgeAlert'} size={11} />
                                  {iss.message}
                                </div>
                              ))}
                            </div>
                            <ProvenanceChip links={c.provenance} title={`Support for: ${c.text.slice(0, 60)}…`} />
                          </div>
                        )
                      })}
                    </div>
                  )}
                </section>
              )
            })}
          </article>
        </div>
      </div>
    </div>
  )
}
