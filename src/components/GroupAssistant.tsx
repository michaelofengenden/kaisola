import { memo, useEffect, useMemo, useState } from 'react'
import { Assistant } from './Assistant'
import { Icon } from './Icon'
import { ProviderIcon } from './ProviderIcon'
import { bridge, type AcpAgent, type AcpControls, type AcpPreset, type WorktreeFile } from '../lib/bridge'
import {
  useKaisola,
  type AssistantDraft,
  type AssistantRuntime,
  type GroupSessionMember,
  type GroupSessionPhase,
  type WorktreeSession,
} from '../store/store'

const EMPTY_DRAFT: AssistantDraft = { text: '', attachments: [], mentions: [], speed: 'default' }
const MAX_SHARED_TEXT = 28_000
type CandidateDiff = { ok: boolean; patch?: string; files?: WorktreeFile[]; message?: string }

const modelControl = (controls?: AcpControls) => {
  if (controls?.models) return {
    value: controls.models.currentModelId,
    options: controls.models.availableModels.map((model) => ({ value: model.modelId, name: model.name })),
  }
  const config = controls?.configOptions.find((option) => option.category === 'model' || /model/i.test(option.id))
  return config ? { value: config.currentValue, options: config.options } : null
}

const TURN_TIME_BASELINE = 1_000_000_000_000
const turnsAfter = (runtime: AssistantRuntime | undefined, baseline = 0, legacyStartedAt = 0) => {
  const turns = runtime?.turns ?? []
  // Current stages store a wall-clock boundary because the live runtime is a
  // rolling 40-turn window. Array indexes stop advancing once that window is
  // full. Older persisted Mesh sessions stored an index; their parent thread's
  // lastActivityAt is the stage start and safely migrates them in place.
  if (baseline >= TURN_TIME_BASELINE) return turns.filter((turn) => (turn.at ?? 0) >= baseline)
  if (legacyStartedAt >= TURN_TIME_BASELINE) return turns.filter((turn) => (turn.at ?? 0) >= legacyStartedAt)
  return turns.slice(baseline)
}

const responseAfter = (runtime: AssistantRuntime | undefined, baseline = 0, legacyStartedAt = 0): string =>
  turnsAfter(runtime, baseline, legacyStartedAt)
    .filter((turn) => turn.kind === 'assistant' && turn.text.trim())
    .map((turn) => turn.text.trim())
    .join('\n\n')
    .slice(-MAX_SHARED_TEXT)

const phaseLabel: Record<GroupSessionPhase, string> = {
  idle: 'Ready',
  answering: 'Independent scouting',
  ready: 'Scouts ready',
  negotiating: 'Role negotiation',
  'plan-ready': 'Negotiation ready',
  assigning: 'Writing role contract',
  assigned: 'Plan awaiting approval',
  executing: 'Isolated execution',
  'execution-ready': 'Changes ready',
  reviewing: 'Cross-review',
  'merge-ready': 'Integration awaiting approval',
  integrating: 'Integrating',
  done: 'Complete',
  critiquing: 'Role negotiation',
  'review-ready': 'Negotiation ready',
  synthesizing: 'Writing role contract',
}

const runningPhases = new Set<GroupSessionPhase>(['answering', 'negotiating', 'assigning', 'executing', 'reviewing', 'integrating', 'critiquing', 'synthesizing'])

function memberText(
  member: GroupSessionMember,
  saved: Record<string, string> | undefined,
  runtimes: Record<string, AssistantRuntime>,
  baselines: Record<string, number> | undefined,
  legacyStartedAt: number | undefined,
) {
  return saved?.[member.threadId] ?? responseAfter(runtimes[member.threadId], baselines?.[member.threadId] ?? 0, legacyStartedAt)
}

const memberPacket = (members: GroupSessionMember[], values?: Record<string, string>) =>
  members.map((member) => `${member.label}:\n${values?.[member.threadId] ?? '(none)'}`).join('\n\n---\n\n')

/**
 * A bounded hybrid team protocol over private ACP sessions:
 * scout independently → negotiate once → approve a role contract → execute in
 * isolated worktrees → cross-review → one integration owner. Humans approve
 * every state-changing boundary; agents never free-chat or share a checkout.
 */
export const GroupAssistant = memo(function GroupAssistant({ threadId }: { threadId: string }) {
  const thread = useKaisola((state) => state.assistantThreads.find((candidate) => candidate.id === threadId))
  const childThreads = useKaisola((state) => state.assistantThreads.filter((candidate) => candidate.groupParentId === threadId))
  const runtimes = useKaisola((state) => state.assistantRuntimes)
  const projectId = useKaisola((state) => state.activeProjectId)
  const workspacePath = useKaisola((state) => state.workspacePath)
  const enqueue = useKaisola((state) => state.enqueueAssistantPrompt)
  const setGroup = useKaisola((state) => state.setGroupSession)
  const addGroupMember = useKaisola((state) => state.addGroupMember)
  const removeGroupMember = useKaisola((state) => state.removeGroupMember)
  const setGroupMemberModel = useKaisola((state) => state.setGroupMemberModel)
  const setGroupWorktrees = useKaisola((state) => state.setGroupWorktrees)
  const clearGroupWorktreeSessions = useKaisola((state) => state.clearGroupWorktreeSessions)
  const setThreadCwd = useKaisola((state) => state.setAssistantThreadCwd)
  const setBusy = useKaisola((state) => state.setThreadBusy)
  const requestNewGroup = useKaisola((state) => state.requestNewGroup)
  const pushToast = useKaisola((state) => state.pushToast)
  const [draft, setDraft] = useState('')
  const [transitioning, setTransitioning] = useState(false)
  const [agents, setAgents] = useState<AcpAgent[]>([])
  const [presets, setPresets] = useState<AcpPreset[]>([])
  const group = thread?.group
  const members = group?.members ?? []
  const phase = group?.phase ?? 'idle'

  useEffect(() => {
    if (!group || phase !== 'idle') return
    let live = true
    const keys = members.map((member) => `${member.agentKey}::${member.threadId}`)
    const refreshRoster = () => {
      void bridge.acp.status(keys).then((result) => { if (live) setAgents(result.agents) }).catch(() => {})
    }
    refreshRoster()
    void bridge.acp.presets().then((rows) => { if (live) setPresets(rows) }).catch(() => {})
    const timer = window.setInterval(refreshRoster, 1_500)
    return () => { live = false; window.clearInterval(timer) }
  }, [group, members, phase])

  const liveValues = (saved?: Record<string, string>) => Object.fromEntries(
    members.map((member) => [member.threadId, memberText(member, saved, runtimes, group?.baselines, thread?.lastActivityAt)]),
  )
  const currentAnswers = useMemo(
    () => liveValues(group?.answers),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [group?.answers, group?.baselines, members, runtimes],
  )
  const currentNegotiations = useMemo(
    () => liveValues(group?.negotiations ?? group?.critiques),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [group?.baselines, group?.critiques, group?.negotiations, members, runtimes],
  )
  const currentExecutions = useMemo(
    () => liveValues(group?.executions),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [group?.baselines, group?.executions, members, runtimes],
  )
  const currentReviews = useMemo(
    () => liveValues(group?.reviews),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [group?.baselines, group?.reviews, members, runtimes],
  )

  const stageSettled = (targets: GroupSessionMember[]) => targets.every((member) => {
    const child = childThreads.find((candidate) => candidate.id === member.threadId)
    const baseline = group?.baselines?.[member.threadId] ?? 0
    return !!child && !child.busy && !!responseAfter(runtimes[member.threadId], baseline, thread?.lastActivityAt)
  })
  const stageValues = (targets: GroupSessionMember[]) => Object.fromEntries(
    targets.map((member) => [member.threadId, responseAfter(runtimes[member.threadId], group?.baselines?.[member.threadId] ?? 0, thread?.lastActivityAt)]),
  )

  // Promote only after every addressed worker returned a real assistant turn.
  // Snapshots preserve the shared audit trail when private runtimes later page.
  useEffect(() => {
    if (!group || members.length < 2) return
    const legacyNegotiating = phase === 'critiquing'
    const legacyAssigning = phase === 'synthesizing'
    if (phase === 'review-ready') {
      setGroup(threadId, { phase: 'plan-ready', negotiations: group.negotiations ?? group.critiques }, projectId)
    } else if (phase === 'answering' && stageSettled(members)) {
      setGroup(threadId, { phase: 'ready', answers: stageValues(members), baselines: undefined }, projectId)
      setBusy(threadId, false, projectId)
    } else if ((phase === 'negotiating' || legacyNegotiating) && stageSettled(members)) {
      setGroup(threadId, { phase: 'plan-ready', negotiations: stageValues(members), baselines: undefined }, projectId)
      setBusy(threadId, false, projectId)
    } else if (phase === 'assigning' || legacyAssigning) {
      const lead = members.find((member) => member.threadId === group.leadThreadId) ?? members[members.length - 1]
      if (lead && stageSettled([lead])) {
        setGroup(threadId, { phase: 'assigned', jointPlan: responseAfter(runtimes[lead.threadId], group.baselines?.[lead.threadId] ?? 0, thread?.lastActivityAt), baselines: undefined }, projectId)
        setBusy(threadId, false, projectId)
      }
    } else if (phase === 'executing' && stageSettled(members)) {
      setGroup(threadId, { phase: 'execution-ready', executions: stageValues(members), baselines: undefined }, projectId)
      setBusy(threadId, false, projectId)
    } else if (phase === 'reviewing' && stageSettled(members)) {
      setGroup(threadId, { phase: 'merge-ready', reviews: stageValues(members), baselines: undefined }, projectId)
      setBusy(threadId, false, projectId)
    } else if (phase === 'integrating') {
      const lead = members.find((member) => member.threadId === group.leadThreadId) ?? members[members.length - 1]
      if (lead && stageSettled([lead])) {
        const integration = responseAfter(runtimes[lead.threadId], group.baselines?.[lead.threadId] ?? 0, thread?.lastActivityAt)
        setGroup(threadId, { phase: 'done', integration, synthesis: integration, baselines: undefined }, projectId)
        setBusy(threadId, false, projectId)
      }
    }
    // stage helpers are derived from the selected live project slice.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [childThreads, group, members, phase, projectId, runtimes, setBusy, setGroup, threadId])

  const queueStage = (nextPhase: GroupSessionPhase, prompts: Record<string, string>, targets = members) => {
    const startedAt = Date.now()
    const baselines = Object.fromEntries(targets.map((member) => [member.threadId, startedAt]))
    setGroup(threadId, { phase: nextPhase, baselines, error: undefined }, projectId)
    setBusy(threadId, true, projectId)
    for (const member of targets) {
      const text = prompts[member.threadId]
      if (text) enqueue(member.threadId, { ...EMPTY_DRAFT, text }, undefined, projectId)
    }
  }

  const askBoth = () => {
    const task = draft.trim()
    if (!task || members.length < 2) return
    setDraft('')
    setGroup(threadId, {
      task,
      answers: {},
      negotiations: {},
      jointPlan: undefined,
      executions: {},
      reviews: {},
      integration: undefined,
      synthesis: undefined,
      worktrees: undefined,
      changedFiles: undefined,
      leadThreadId: undefined,
      error: undefined,
    }, projectId)
    queueStage('answering', Object.fromEntries(members.map((member) => [
      member.threadId,
      `You are ${member.label}, scouting independently inside a bounded Kaisola team protocol. Analyze the task before seeing the other scout's view. Do not edit files. Return: your model of the problem, a proposed approach, risks, likely ownership boundaries, and observable acceptance criteria.\n\nMission:\n${task}`,
    ])))
  }

  const negotiate = () => {
    if (!group?.answers) return
    queueStage('negotiating', Object.fromEntries(members.map((member) => {
      const peers = members.filter((candidate) => candidate.threadId !== member.threadId)
      return [member.threadId,
        `You are ${member.label} in the only role-negotiation round. Compare your proposal with every peer proposal below. Do not edit files. Recommend orthogonal assignments with one owner each, explicit interfaces, acceptance tests, integration order, stop conditions, and any disagreement the coordinator must resolve. Acknowledge what you accept from peers rather than silently assuming agreement.\n\nMission:\n${group.task ?? ''}\n\nYour proposal:\n${group.answers?.[member.threadId] ?? ''}\n\nPeer proposals:\n${memberPacket(peers, group.answers)}`,
      ]
    })))
  }

  const writeRoleContract = () => {
    if (!group?.answers || !group.negotiations) return
    const lead = members.find((member) => /codex/i.test(member.agentKey)) ?? members[members.length - 1]
    if (!lead) return
    setGroup(threadId, { leadThreadId: lead.threadId }, projectId)
    const packet = `INDEPENDENT SCOUTS\n${memberPacket(members, group.answers)}\n\nNEGOTIATION\n${memberPacket(members, group.negotiations)}`.slice(-MAX_SHARED_TEXT * 2)
    queueStage('assigning', {
      [lead.threadId]: `Act as the coordinator, not an implementer yet. Resolve the bounded negotiation into one role contract. Do not edit files. Use these exact headings: Mission intent; Shared invariants; Assignments; Integration order; Acceptance tests; Stop and escalation conditions. Name every participant and assign orthogonal work with one owner per subsystem/file boundary. Identify any shared interface that must be agreed before execution.\n\nMission:\n${group.task ?? ''}\n\nTeam packet:\n${packet}`,
    }, [lead])
  }

  const executeIsolated = async () => {
    if (!group?.jointPlan || !workspacePath || transitioning) {
      if (!workspacePath) setGroup(threadId, { error: 'Open a git workspace before isolated execution.' }, projectId)
      return
    }
    setTransitioning(true)
    try {
      const attempts = await Promise.all(members.map(async (member, index) => {
        const taskId = `group-${Date.now().toString(36)}-${index}`
        const result = await bridge.worktree.create({ repo: workspacePath, taskId })
        return { member, taskId, result }
      }))
      const failed = attempts.find((attempt) => !attempt.result.ok || !attempt.result.path)
      if (failed) {
        await Promise.all(attempts.filter((attempt) => attempt.result.ok).map((attempt) => bridge.worktree.remove({ taskId: attempt.taskId, repo: workspacePath })))
        setGroup(threadId, { error: failed.result.message ?? 'Could not create isolated worktrees.' }, projectId)
        return
      }
      const worktrees = Object.fromEntries(attempts.map(({ member, taskId, result }) => [member.threadId, {
        taskId,
        path: result.path!,
        branch: result.branch ?? `pz/${taskId}`,
        repo: workspacePath,
      } satisfies WorktreeSession]))
      setGroupWorktrees(threadId, worktrees, projectId)
      await Promise.all(members.map((member) => bridge.acp.disconnect(`${member.agentKey}::${member.threadId}`).catch(() => ({ ok: false }))))
      await new Promise((resolve) => window.setTimeout(resolve, 180))
      queueStage('executing', Object.fromEntries(members.map((member) => [member.threadId,
        `Execute only your named assignment from the approved role contract. You are the sole write owner of this isolated worktree: ${worktrees[member.threadId].path}. Do not work on the peer's assignment or main checkout. Honor shared invariants, run relevant tests, and stop if the contract is ambiguous or requires overlapping ownership. Finish with: files changed, tests run, unresolved risks, and integration notes.\n\nMission:\n${group.task ?? ''}\n\nApproved role contract:\n${group.jointPlan}`,
      ])))
    } finally {
      setTransitioning(false)
    }
  }

  const crossReview = async () => {
    if (!group?.worktrees || transitioning) return
    setTransitioning(true)
    try {
      const diffs = await Promise.all(members.map(async (member) => {
        const wt = group.worktrees?.[member.threadId]
        if (!wt) return { member, wt, result: { ok: false, message: 'Missing worktree.' } as CandidateDiff }
        // Freeze the candidate before review. The verifier therefore reviews
        // the exact commit that the integration gate will later merge.
        const finalized = await bridge.worktree.finalize({
          taskId: wt.taskId,
          repo: wt.repo,
          message: `kaisola group candidate: ${member.label} assignment`,
        })
        const result: CandidateDiff = finalized.ok
          ? await bridge.worktree.diff({ taskId: wt.taskId })
          : { ok: false, message: finalized.message ?? `Could not freeze ${member.label}'s candidate.` }
        return { member, wt, result }
      }))
      const failed = diffs.find((item) => !item.result.ok)
      if (failed) {
        setGroup(threadId, { error: failed.result.message ?? 'Could not inspect a worker diff.' }, projectId)
        return
      }
      const changedFiles = Object.fromEntries(diffs.map((item) => [item.member.threadId, (item.result.files ?? []) as WorktreeFile[]]))
      setGroup(threadId, { changedFiles }, projectId)
      queueStage('reviewing', Object.fromEntries(members.map((reviewer, reviewerIndex) => {
        const peer = members[(reviewerIndex + 1) % members.length]
        const peerDiff = diffs.find((item) => item.member.threadId === peer.threadId)!
        return [reviewer.threadId,
          `Cross-review ${peer.label}'s implementation as an independent verifier. Do not edit either worktree. Check the approved role boundary, correctness, tests, regressions, security, and integration risk. Challenge claims with concrete evidence from the patch or peer worktree. Return: verdict, blocking findings, non-blocking findings, and required integration checks.\n\nMission:\n${group.task ?? ''}\n\nApproved role contract:\n${group.jointPlan ?? ''}\n\n${peer.label} execution report:\n${group.executions?.[peer.threadId] ?? ''}\n\nPeer worktree: ${peerDiff.wt?.path ?? ''}\n\nPatch:\n${(peerDiff.result.patch ?? '').slice(-MAX_SHARED_TEXT)}`,
        ]
      })))
    } finally {
      setTransitioning(false)
    }
  }

  const integrate = async () => {
    if (!group?.worktrees || !workspacePath || transitioning) return
    const lead = members.find((member) => member.threadId === group.leadThreadId) ?? members.find((member) => /codex/i.test(member.agentKey)) ?? members[members.length - 1]
    if (!lead) return
    setTransitioning(true)
    try {
      for (const member of members) {
        const wt = group.worktrees[member.threadId]
        const finalized = await bridge.worktree.finalize({ taskId: wt.taskId, repo: wt.repo, message: `kaisola group: ${member.label} assignment` })
        if (!finalized.ok) {
          setGroup(threadId, { error: finalized.message ?? `Could not finalize ${member.label}'s work.` }, projectId)
          return
        }
      }
      let conflict = ''
      const remaining: string[] = []
      for (let index = 0; index < members.length; index++) {
        const member = members[index]
        const wt = group.worktrees[member.threadId]
        const merged = await bridge.worktree.merge({ taskId: wt.taskId, repo: wt.repo })
        if (!merged.ok) {
          if (!merged.conflicted) {
            setGroup(threadId, { error: merged.message ?? `Could not merge ${member.label}'s branch.` }, projectId)
            return
          }
          conflict = `A conflict began while merging ${wt.branch}.`
          remaining.push(...members.slice(index + 1).map((candidate) => group.worktrees![candidate.threadId].branch))
          break
        }
      }
      if (!conflict) {
        const cleanup = await Promise.all(members.map((member) => {
          const wt = group.worktrees![member.threadId]
          return bridge.worktree.remove({ taskId: wt.taskId, repo: wt.repo })
        }))
        const cleanupFailure = cleanup.find((result) => !result.ok)
        if (cleanupFailure) {
          pushToast('warn', `The reviewed changes merged, but a temporary worktree could not be removed${cleanupFailure.message ? ` — ${cleanupFailure.message}` : ''}.`)
        } else {
          clearGroupWorktreeSessions(threadId, workspacePath, projectId)
        }
      }
      setThreadCwd(lead.threadId, workspacePath, projectId)
      setGroup(threadId, { leadThreadId: lead.threadId }, projectId)
      await bridge.acp.disconnect(`${lead.agentKey}::${lead.threadId}`).catch(() => ({ ok: false }))
      await new Promise((resolve) => window.setTimeout(resolve, 180))
      queueStage('integrating', {
        [lead.threadId]: `You are the sole integration owner in the main workspace: ${workspacePath}. The workers' branches were finalized and merge was attempted. Inspect git status before acting. ${conflict || 'Both branches merged cleanly.'}${remaining.length ? ` Resolve the current conflict, then merge the remaining branches: ${remaining.join(', ')}.` : ''} Reconcile only integration issues, run the approved acceptance tests plus relevant regression checks, and leave the main workspace in a coherent finished state. Finish with a concise implementation summary, exact tests, and any remaining human decision.\n\nMission:\n${group.task ?? ''}\n\nRole contract:\n${group.jointPlan ?? ''}\n\nExecution reports:\n${memberPacket(members, group.executions)}\n\nCross-reviews:\n${memberPacket(members, group.reviews)}`,
      }, [lead])
    } finally {
      setTransitioning(false)
    }
  }

  if (!thread || !group) return null
  const running = runningPhases.has(phase)
  const negotiated = group.negotiations ?? group.critiques
  const finalText = group.integration ?? group.synthesis
  const participantPresets = presets.filter((preset) => !preset.hidden && !preset.terminalOnly && preset.id !== 'group')
  const chooseModel = async (member: GroupSessionMember, value: string) => {
    const key = `${member.agentKey}::${member.threadId}`
    const control = modelControl(agents.find((agent) => agent.key === key)?.controls)
    const label = control?.options.find((option) => option.value === value)?.name ?? value
    const result = await bridge.acp.setModel(key, value).catch(() => ({ ok: false, message: 'The model selection could not be sent.' }))
    if (result.ok) setGroupMemberModel(threadId, member.threadId, value, label, projectId)
    else setGroup(threadId, { error: result.message ?? `Could not select ${label} for ${member.label}.` }, projectId)
  }

  return (
    <div className="group-assistant" data-phase={phase}>
      <header className="group-head">
        <span className="group-mark"><Icon name="Network" size={14} /></span>
        <div><strong>Kaisola Mesh</strong><small>{members.length} agents · scout · align · divide · verify · integrate</small></div>
        <span className="grow" />
        <span className="group-phase" data-running={running || undefined}>{phaseLabel[phase]}</span>
      </header>

      <div className="group-stream">
        {!group.task && (
          <div className="group-empty">
            <Icon name="Network" size={24} />
            <strong>One mission, multiple models, explicit ownership.</strong>
            <p>Mesh lets a bounded team scout independently, negotiate one role split, work in isolated git worktrees, cross-review, and hand one integration owner the final merge.</p>
            <small>Every state-changing boundary waits for your approval.</small>
            <div className="group-roster" aria-label="Mesh participants">
              {members.map((member) => {
                const key = `${member.agentKey}::${member.threadId}`
                const control = modelControl(agents.find((agent) => agent.key === key)?.controls)
                const value = control?.value ?? member.modelId ?? ''
                return <div className="group-roster-row" key={member.threadId}>
                  <ProviderIcon provider={member.agentKey} name={member.label} size={14} />
                  <span className="truncate">{member.label}</span>
                  <select
                    value={value}
                    disabled={!control?.options.length}
                    onChange={(event) => { void chooseModel(member, event.target.value) }}
                    title={control ? `Model for ${member.label}` : `${member.label} is connecting`}
                  >
                    {!value && <option value="">Provider default</option>}
                    {(control?.options ?? []).map((option) => <option value={option.value} key={option.value}>{option.name}</option>)}
                  </select>
                  {members.length > 2 && <button className="btn-icon" onClick={() => {
                    void bridge.acp.disconnect(`${member.agentKey}::${member.threadId}`)
                    removeGroupMember(threadId, member.threadId, projectId)
                  }} title={`Remove ${member.label}`}><Icon name="X" size={12} /></button>}
                </div>
              })}
              <select
                className="group-add-member"
                value=""
                onChange={(event) => {
                  const preset = participantPresets.find((row) => row.id === event.target.value)
                  if (preset) addGroupMember(threadId, preset.id, preset.name, projectId)
                }}
              >
                <option value="">+ Add another model</option>
                {participantPresets.map((preset) => <option value={preset.id} key={preset.id}>{preset.name}</option>)}
              </select>
            </div>
          </div>
        )}
        {group.error && <div className="group-error"><Icon name="AlertTriangle" size={13} />{group.error}</div>}
        {group.task && <section className="group-task"><span>Mission</span><p>{group.task}</p></section>}

        {(phase !== 'idle' || group.answers) && (
          <GroupPair title="Independent scouts" members={members} values={currentAnswers} childThreads={childThreads} active={phase === 'answering'} />
        )}
        {(negotiated || phase === 'negotiating' || phase === 'critiquing') && (
          <GroupPair title="Role negotiation" members={members} values={currentNegotiations} childThreads={childThreads} active={phase === 'negotiating' || phase === 'critiquing'} compact />
        )}
        {(group.jointPlan || phase === 'assigning' || phase === 'synthesizing') && (
          <section className="group-final group-contract">
            <header><Icon name="ClipboardList" size={14} /><strong>Role contract</strong></header>
            <p>{group.jointPlan || 'Coordinator is resolving ownership, interfaces, tests, and stop conditions…'}</p>
          </section>
        )}
        {(group.worktrees || phase === 'executing' || group.executions) && (
          <section className="group-execution">
            <h3>Isolated execution</h3>
            {members.map((member) => {
              const wt = group.worktrees?.[member.threadId]
              const files = group.changedFiles?.[member.threadId] ?? []
              return <article key={`exec:${member.threadId}`}>
                <header><ProviderIcon provider={member.agentKey} name={member.label} size={14} /><strong>{member.label}</strong>{wt && <span className="group-branch">{wt.branch}</span>}</header>
                <p>{currentExecutions[member.threadId] || (phase === 'executing' ? 'Working in an isolated checkout…' : 'Awaiting execution')}</p>
                {files.length > 0 && <small>{files.map((file) => file.path).join(' · ')}</small>}
              </article>
            })}
          </section>
        )}
        {(group.reviews || phase === 'reviewing') && (
          <GroupPair title="Cross-review" members={members} values={currentReviews} childThreads={childThreads} active={phase === 'reviewing'} compact />
        )}
        {(phase === 'integrating' || finalText) && (
          <section className="group-final">
            <header><Icon name="CheckCircle2" size={14} /><strong>Integrated result</strong></header>
            <p>{finalText || 'The integration owner is reconciling branches and running the shared acceptance tests…'}</p>
          </section>
        )}
      </div>

      <footer className="group-composer">
        {phase === 'idle' && <><textarea value={draft} onChange={(event) => setDraft(event.target.value)} placeholder="Give Claude and Codex one mission…" rows={2} /><button className="group-primary" onClick={askBoth} disabled={!draft.trim()} title="Start independent scouting"><Icon name="ArrowUp" size={15} /></button></>}
        {phase === 'ready' && <button className="group-action" onClick={negotiate}><Icon name="MessageSquarePlus" size={14} /> Compare approaches and negotiate roles</button>}
        {(phase === 'plan-ready' || phase === 'review-ready') && <button className="group-action" onClick={writeRoleContract}><Icon name="ClipboardList" size={14} /> Approve negotiation and write role contract</button>}
        {phase === 'assigned' && <button className="group-action" onClick={() => void executeIsolated()} disabled={transitioning}><Icon name="GitBranch" size={14} /> Approve plan and create isolated worktrees</button>}
        {phase === 'execution-ready' && <button className="group-action" onClick={() => void crossReview()} disabled={transitioning}><Icon name="ScanSearch" size={14} /> Cross-review both implementations</button>}
        {phase === 'merge-ready' && <button className="group-action" onClick={() => void integrate()} disabled={transitioning}><Icon name="GitMerge" size={14} /> Approve and integrate reviewed work</button>}
        {phase === 'done' && <button className="group-action" onClick={requestNewGroup}><Icon name="Plus" size={14} /> Start another group session</button>}
        {(running || transitioning) && <span className="group-running"><span className="session-busy" /> {transitioning ? 'Preparing safe transition' : phaseLabel[phase]}…</span>}
      </footer>

      <div className="group-workers" aria-hidden="true">
        {members.map((member) => <Assistant key={member.threadId} threadId={member.threadId} />)}
      </div>
    </div>
  )
})

function GroupPair({
  title,
  members,
  values,
  childThreads,
  active,
  compact = false,
}: {
  title: string
  members: GroupSessionMember[]
  values: Record<string, string>
  childThreads: Array<{ id: string; busy: boolean }>
  active: boolean
  compact?: boolean
}) {
  return <section className={compact ? 'group-review' : 'group-results-wrap'}>
    <h3>{title}</h3>
    <div className={compact ? undefined : 'group-results'}>
      {members.map((member) => {
        const busy = active && childThreads.find((thread) => thread.id === member.threadId)?.busy
        return <article className={compact ? undefined : 'group-result'} key={`${title}:${member.threadId}`}>
          <header><ProviderIcon provider={member.agentKey} name={member.label} size={compact ? 13 : 15} /><strong>{member.label}</strong>{member.modelLabel && <small className="group-model-label truncate">{member.modelLabel}</small>}{busy && <span className="session-busy" />}</header>
          <p>{values[member.threadId] || (active ? 'Working…' : 'No response recorded')}</p>
        </article>
      })}
    </div>
  </section>
}
