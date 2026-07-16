const round = (value) => Math.round(value * 10) / 10

const percentile = (values, fraction) => {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)] ?? 0
}

const DIAGNOSTIC_SHAPE_KEYS = [
  'domNodes', 'canvases', 'xterms', 'projectTabs', 'projectSlices',
  'closedProjects', 'terminalMeta', 'termRemounts', 'termDrafts',
]

function evaluateLifecycleRun({
  baseline,
  baselineDiagnostics,
  checkpoints,
  checkpointDiagnostics,
  retained,
  retainedDiagnostics,
  continuity,
}) {
  const retainedSeriesMiB = checkpoints.map((sample) => sample.medianMiB)
  const monotonicRetainedGrowth = retainedSeriesMiB.length > 1
    && retainedSeriesMiB.slice(1).every((value, index) => value > retainedSeriesMiB[index] + 1)
  const overheadMiB = round(retained.medianMiB - baseline.medianMiB)
  // The soft limit is the cross-run quality bar. A single Chromium native
  // allocator outlier may exceed it, but no individual run may cross 1.5x.
  const thresholdMiB = round(Math.max(30, baseline.medianMiB * 0.1))
  const hardThresholdMiB = round(thresholdMiB * 1.5)

  const observedDiagnostics = [...checkpointDiagnostics, retainedDiagnostics]
  const jsHeapMeasured = Number.isFinite(baselineDiagnostics?.usedJsHeapMiB)
    && observedDiagnostics.every((sample) => Number.isFinite(sample?.usedJsHeapMiB))
  const jsHeapSeriesMiB = observedDiagnostics.map((sample) => sample?.usedJsHeapMiB ?? 0)
  const monotonicJsHeapGrowth = jsHeapMeasured && jsHeapSeriesMiB.length > 1
    && jsHeapSeriesMiB.slice(1).every((value, index) => value > jsHeapSeriesMiB[index] + 0.5)
  const jsHeapGrowthMiB = jsHeapMeasured
    ? round(retainedDiagnostics.usedJsHeapMiB - baselineDiagnostics.usedJsHeapMiB)
    : Number.POSITIVE_INFINITY
  const jsHeapThresholdMiB = round(Math.max(5, (baselineDiagnostics?.usedJsHeapMiB ?? 0) * 0.25))
  const stableRetainedShape = observedDiagnostics.every((sample) =>
    DIAGNOSTIC_SHAPE_KEYS.every((key) => sample?.[key] === baselineDiagnostics?.[key]),
  )
  const stableProcessCount = [...checkpoints, retained].every((sample) => sample.processCount === baseline.processCount)
  const continuityPass = continuity.every((row) =>
    row.pidStable && row.output && row.draft && row.agent && row.activeFile && row.notificationSetting,
  )

  return {
    retainedSeriesMiB,
    overheadMiB,
    thresholdMiB,
    hardThresholdMiB,
    monotonicRetainedGrowth,
    jsHeapSeriesMiB,
    jsHeapGrowthMiB,
    jsHeapThresholdMiB,
    monotonicJsHeapGrowth,
    stableRetainedShape,
    stableProcessCount,
    pass: overheadMiB <= hardThresholdMiB
      && jsHeapMeasured
      && jsHeapGrowthMiB <= jsHeapThresholdMiB
      && !monotonicJsHeapGrowth
      && stableRetainedShape
      && stableProcessCount
      && continuityPass,
  }
}

function evaluateLifecycleComparison(rows, rounds = rows.length) {
  const thresholdPasses = rows.filter((row) => row.overheadMiB <= row.thresholdMiB).length
  const hardThresholdPasses = rows.filter((row) => row.overheadMiB <= row.hardThresholdMiB).length
  const medianOverheadMiB = percentile(rows.map((row) => row.overheadMiB), 0.5)
  const medianThresholdMiB = percentile(rows.map((row) => row.thresholdMiB), 0.5)
  return {
    thresholdPasses,
    hardThresholdPasses,
    medianThresholdMiB: round(medianThresholdMiB),
    monotonicRuns: rows.filter((row) => row.monotonicRetainedGrowth).length,
    monotonicJsHeapRuns: rows.filter((row) => row.monotonicJsHeapGrowth).length,
    pass: rounds >= 5
      && rows.length === rounds
      && rows.every((row) => row.pass)
      && thresholdPasses >= rounds - 1
      && hardThresholdPasses === rounds
      && medianOverheadMiB <= medianThresholdMiB,
  }
}

module.exports = { DIAGNOSTIC_SHAPE_KEYS, evaluateLifecycleRun, evaluateLifecycleComparison }
