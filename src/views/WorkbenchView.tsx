import { useKaisola } from '../store/store'
import { WORKBENCH_TABS } from '../lib/stages'
import { Icon } from '../components/Icon'
import type { TrajectoryStage } from '../domain/types'
import { CampaignView } from './CampaignView'
import { IdeasView } from './IdeasView'
import { ExperimentsView } from './ExperimentsView'
import { RunsView } from './RunsView'

/**
 * The Workbench — Campaign, Ideas, Experiments and Runs in one place. This is
 * where the researcher actually lives: define a campaign, form a hypothesis,
 * plan the experiment, run it.
 */
export function WorkbenchView() {
  const stage = useKaisola((s) => s.stage)
  const setStage = useKaisola((s) => s.setStage)
  const active: TrajectoryStage = (['campaign', 'ideas', 'experiments', 'runs'] as TrajectoryStage[]).includes(stage) ? stage : 'campaign'

  return (
    <div className="view workbench">
      <div className="workbench-tabs">
        {WORKBENCH_TABS.map((t) => (
          <button key={t.id} className="wb-tab" data-active={active === t.id} onClick={() => setStage(t.id)}>
            <Icon name={t.icon} size={14} />
            {t.label}
          </button>
        ))}
      </div>
      <div className="workbench-body">
        {active === 'campaign' && <CampaignView />}
        {active === 'ideas' && <IdeasView />}
        {active === 'experiments' && <ExperimentsView />}
        {active === 'runs' && <RunsView />}
      </div>
    </div>
  )
}
