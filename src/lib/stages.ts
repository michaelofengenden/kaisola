import type { TrajectoryStage } from '../domain/types'

export interface StageMeta {
  id: TrajectoryStage
  label: string
  short: string
  /** lucide-react icon name. */
  icon: string
  blurb: string
}

/** The trajectory spine, in order. The left rail renders exactly this. */
export const STAGES: StageMeta[] = [
  { id: 'corpus', label: 'Corpus', short: 'Corpus', icon: 'Library', blurb: 'Papers, repos, datasets & notes' },
  { id: 'claims', label: 'Claim Graph', short: 'Claims', icon: 'Network', blurb: 'Claims, methods, limitations & contradictions' },
  { id: 'questions', label: 'Questions', short: 'Questions', icon: 'HelpCircle', blurb: 'Open research questions' },
  { id: 'campaign', label: 'Campaign', short: 'Campaign', icon: 'Target', blurb: 'Objective, evaluator, budget & attempts' },
  { id: 'ideas', label: 'Ideas', short: 'Ideas', icon: 'Lightbulb', blurb: 'Evidence-grounded hypotheses' },
  { id: 'experiments', label: 'Experiments', short: 'Plan', icon: 'ListChecks', blurb: 'Specs, baselines, ablations & metrics' },
  { id: 'runs', label: 'Runs', short: 'Runs', icon: 'Terminal', blurb: 'Execution & the auto lab notebook' },
  { id: 'analysis', label: 'Analysis', short: 'Analysis', icon: 'BarChart3', blurb: 'Results, figures — real or noise?' },
  { id: 'manuscript', label: 'Manuscript', short: 'Write', icon: 'FileText', blurb: 'Artifact-grounded writing & trust' },
  { id: 'review', label: 'Review', short: 'Review', icon: 'Gavel', blurb: 'Simulated peer review' },
  { id: 'files', label: 'Files', short: 'Files', icon: 'FolderTree', blurb: 'Browse the workspace repo' },
]

export function stageMeta(id: TrajectoryStage): StageMeta {
  return STAGES.find((s) => s.id === id) ?? STAGES[0]
}

/**
 * The sidebar nav groups. Ideas + Experiments + Runs collapse into one
 * "Workbench" — the researcher's home base between ideas and execution. A group
 * is active when the current stage is one of its `matches`.
 */
export interface NavGroup {
  id: TrajectoryStage // the stage to navigate to when clicked
  label: string
  icon: string
  blurb: string
  matches: TrajectoryStage[]
}

export const NAV_GROUPS: NavGroup[] = [
  { id: 'files', label: 'Files', icon: 'FolderTree', blurb: 'Browse the agent workspace repo', matches: ['files'] },
  { id: 'corpus', label: 'Corpus', icon: 'Library', blurb: 'Papers, repos, datasets & notes', matches: ['corpus'] },
  { id: 'claims', label: 'Claim Graph', icon: 'Network', blurb: 'Claims, methods & contradictions', matches: ['claims'] },
  { id: 'questions', label: 'Questions', icon: 'HelpCircle', blurb: 'Open research questions', matches: ['questions'] },
  { id: 'campaign', label: 'Workbench', icon: 'FlaskConical', blurb: 'Campaign, ideas, experiments & runs — the home base', matches: ['campaign', 'ideas', 'experiments', 'runs'] },
  { id: 'analysis', label: 'Analysis', icon: 'BarChart3', blurb: 'Results, figures — real or noise?', matches: ['analysis'] },
  { id: 'manuscript', label: 'Manuscript', icon: 'FileText', blurb: 'Artifact-grounded writing & trust', matches: ['manuscript'] },
  { id: 'review', label: 'Review', icon: 'Gavel', blurb: 'Simulated peer review', matches: ['review'] },
]

/** The Workbench sub-tabs. */
export const WORKBENCH_TABS: { id: TrajectoryStage; label: string; icon: string }[] = [
  { id: 'campaign', label: 'Campaign', icon: 'Target' },
  { id: 'ideas', label: 'Ideas', icon: 'Lightbulb' },
  { id: 'experiments', label: 'Experiments', icon: 'ListChecks' },
  { id: 'runs', label: 'Runs', icon: 'Terminal' },
]
