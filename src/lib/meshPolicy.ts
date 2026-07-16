export const RUNNING_MESH_PHASES = [
  'answering',
  'negotiating',
  'assigning',
  'executing',
  'reviewing',
  'integrating',
  'critiquing',
  'synthesizing',
  // Idea mode's two bounded passes.
  'idea-initial',
  'idea-reacting',
] as const

const runningMeshPhases = new Set<string>(RUNNING_MESH_PHASES)

export const isRunningMeshPhase = (phase: string | undefined): boolean =>
  !!phase && runningMeshPhases.has(phase)

export interface MeshOrchestrationMarker {
  groupId: string
  attemptId: string
  phase: string
}

interface MeshParentThread {
  id: string
  group?: {
    phase: string
    stageAttemptId?: string
    paused?: boolean
  }
}

/**
 * A queued Mesh prompt is valid only for the exact live stage attempt that
 * minted it. Stop -> Continue creates a new attempt id, so an older async
 * connection/preflight closure can never deliver after the retry begins.
 */
export function isCurrentMeshOrchestration(
  marker: MeshOrchestrationMarker | undefined,
  threads: readonly MeshParentThread[],
): boolean {
  if (!marker) return true
  const group = threads.find((thread) => thread.id === marker.groupId)?.group
  return !!group
    && !group.paused
    && group.phase === marker.phase
    && group.stageAttemptId === marker.attemptId
}
