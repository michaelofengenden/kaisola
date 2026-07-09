import { useEffect, useState } from 'react'
import { useKaisola } from '../../store/store'
import { bridge, isDesktop } from '../../lib/bridge'
import { estimate, fmtUsd, fmtTok, type ModelSums } from '../../lib/prices'

/**
 * The $ chip on a Claude session card — what this session actually cost,
 * summed from its own transcript (per-model, deduped) and priced at list
 * rates. Hover for the per-model token breakdown. Unknown models show raw
 * tokens instead of an invented dollar figure. Refreshes when the session's
 * Stop hook fires — no polling. Settings → Interface → "Session cost chips".
 */
export function CostChip({ termId }: { termId: string }) {
  const showCosts = useKaisola((s) => s.showCosts)
  const isClaude = useKaisola(
    (s) => s.terminals.find((t) => t.id === termId)?.singletonKey === 'agent:claude-code',
  )
  const sid = useKaisola((s) => (s.workspacePath ? s.claudeSessions[s.workspacePath] : undefined))
  const configDir = useKaisola(
    (s) => s.claudeAccounts.find((a) => a.id === s.claudeAccountId)?.configDir,
  )
  const [models, setModels] = useState<ModelSums[] | null>(null)

  useEffect(() => {
    if (!isDesktop || !showCosts || !isClaude || !sid) return
    let dead = false
    const load = () =>
      void bridge.usage
        ?.claudeSession(configDir, sid)
        .then((r) => {
          if (!dead && r.ok && r.models?.length) setModels(r.models)
        })
        .catch(() => {})
    load()
    const off = bridge.claude.onEvent((ev) => {
      if (ev.event === 'Stop' && ev.sessionId === sid) load()
    })
    return () => {
      dead = true
      off()
    }
  }, [isClaude, sid, configDir, showCosts])

  if (!showCosts || !isClaude || !models) return null
  const { usd, known, tokens } = estimate(models)
  const label = known && usd >= 0.005 ? `~${fmtUsd(usd)}` : `${fmtTok(tokens)} tok`
  const title =
    models
      .map(
        (m) =>
          `${m.model}: in ${fmtTok(m.input)} · out ${fmtTok(m.output)} · cache r ${fmtTok(m.cacheRead)} / w ${fmtTok(m.cacheWrite)}`,
      )
      .join('\n') + (known ? '' : '\n(unknown model — tokens shown instead of $)')
  return (
    <span className="pane-cost" title={title}>
      {label}
    </span>
  )
}
