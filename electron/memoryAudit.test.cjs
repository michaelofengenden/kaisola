const test = require('node:test')
const assert = require('node:assert/strict')
const { evaluateLifecycleRun, evaluateLifecycleComparison } = require('./memoryAudit.cjs')

const diagnostic = (heap = 16.3, domNodes = 480) => ({
  usedJsHeapMiB: heap,
  totalJsHeapMiB: 20.7,
  domNodes,
  canvases: 0,
  xterms: 1,
  projectTabs: 3,
  projectSlices: 2,
  closedProjects: 0,
  terminalMeta: 3,
  termRemounts: 0,
  termDrafts: 3,
})

const continuity = [{
  pidStable: true,
  output: true,
  draft: true,
  agent: true,
  activeFile: true,
  notificationSetting: true,
}]

const lifecycle = (overhead = 25, patch = {}) => {
  const baseline = { medianMiB: 580, processCount: 4 }
  const checkpoints = [590, 592, 594, 593, 596].map((medianMiB) => ({ medianMiB, processCount: 4 }))
  const baselineDiagnostics = diagnostic()
  const checkpointDiagnostics = checkpoints.map(() => diagnostic())
  const retained = { medianMiB: baseline.medianMiB + overhead, processCount: 4 }
  const retainedDiagnostics = diagnostic()
  const evaluated = evaluateLifecycleRun({
    baseline,
    baselineDiagnostics,
    checkpoints,
    checkpointDiagnostics,
    retained,
    retainedDiagnostics,
    continuity,
    ...patch,
  })
  return { baseline, baselineDiagnostics, checkpoints, checkpointDiagnostics, retained, retainedDiagnostics, continuity, ...evaluated }
}

test('five-run lifecycle audit tolerates one bounded native RSS arena outlier', () => {
  const rows = [lifecycle(22), lifecycle(24), lifecycle(65), lifecycle(25), lifecycle(26)]
  assert.equal(rows[2].pass, true)
  assert.equal(rows[2].overheadMiB > rows[2].thresholdMiB, true)
  assert.equal(rows[2].overheadMiB <= rows[2].hardThresholdMiB, true)
  assert.equal(evaluateLifecycleComparison(rows).pass, true)
})

test('lifecycle audit fails retained heap, DOM, process, and repeated RSS drift', () => {
  const heap = lifecycle(25, { retainedDiagnostics: diagnostic(23) })
  assert.equal(heap.pass, false)

  const dom = lifecycle(25, { checkpointDiagnostics: [diagnostic(), diagnostic(), diagnostic(16.3, 481), diagnostic(), diagnostic()] })
  assert.equal(dom.pass, false)

  const process = lifecycle(25, { checkpoints: [{ medianMiB: 590, processCount: 5 }] })
  assert.equal(process.pass, false)

  const rows = [lifecycle(22), lifecycle(65), lifecycle(66), lifecycle(25), lifecycle(26)]
  assert.equal(evaluateLifecycleComparison(rows).pass, false)
})
