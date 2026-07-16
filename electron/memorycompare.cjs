// Five-run, real-renderer memory audit: Eco, Live Glass, and lifecycle retention.
// Build first, then run: npm run memory:compare
const { spawn } = require('node:child_process')
const path = require('node:path')
const electron = require('electron')
const { evaluateLifecycleComparison } = require('./memoryAudit.cjs')

const probe = path.join(__dirname, 'perfprobe.cjs')
const rounds = Math.max(1, Math.min(7, Number(process.env.KAISOLA_MEMORY_ROUNDS) || 5))

function run(scenario) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env }
    delete env.ELECTRON_RUN_AS_NODE
    const child = spawn(electron, [probe, scenario], { stdio: ['ignore', 'pipe', 'pipe'], env })
    let output = ''
    child.stdout.on('data', (chunk) => { output += chunk; process.stdout.write(chunk) })
    child.stderr.on('data', (chunk) => { output += chunk; process.stderr.write(chunk) })
    child.on('error', reject)
    child.on('exit', (code) => {
      const pattern = scenario === 'LIFE' ? /MEMORY_LIFECYCLE=(\{[^\n]+\})/g : /PROBE_MEMORY=(\{[^\n]+\})/g
      const match = [...output.matchAll(pattern)].at(-1)
      if (!match) { reject(new Error(`Memory probe ${scenario} produced no result (${code}).`)); return }
      try {
        const parsed = JSON.parse(match[1])
        if (scenario !== 'LIFE' && code !== 0) { reject(new Error(`Memory probe ${scenario} failed (${code}).`)); return }
        resolve(parsed)
      } catch (error) { reject(error) }
    })
  })
}

const percentile = (values, fraction) => {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)] ?? 0
}
const round = (value) => Math.round(value * 10) / 10
const summary = (values) => {
  const median = percentile(values, 0.5)
  const deviations = values.map((value) => Math.abs(value - median))
  return {
    medianMiB: round(median),
    madMiB: round(percentile(deviations, 0.5)),
    minMiB: round(Math.min(...values)),
    maxMiB: round(Math.max(...values)),
    dispersionMiB: round(Math.max(...values) - Math.min(...values)),
  }
}

;(async () => {
  const results = { E: [], G: [], LIFE: [] }
  for (let i = 0; i < rounds; i += 1) {
    results.E.push(await run('E'))
    results.G.push(await run('G'))
    results.LIFE.push(await run('LIFE'))
  }
  const eco = summary(results.E.map((row) => row.medianMiB))
  const glass = summary(results.G.map((row) => row.medianMiB))
  const pairedDeltasMiB = results.G.map((row, index) => round(row.medianMiB - results.E[index].medianMiB))
  const lifecycleOverhead = summary(results.LIFE.map((row) => row.overheadMiB))
  const lifecycleRetained = summary(results.LIFE.map((row) => row.retained.medianMiB))
  const lifecycleAudit = evaluateLifecycleComparison(results.LIFE, rounds)
  const result = {
    rounds,
    material: {
      eco,
      glass,
      deltaMiB: round(pairedDeltasMiB.reduce((sum, value) => sum + value, 0) / pairedDeltasMiB.length),
      pairedDeltasMiB,
    },
    lifecycle: {
      retained: lifecycleRetained,
      overhead: lifecycleOverhead,
      ...lifecycleAudit,
    },
    pass: lifecycleAudit.pass,
    results,
  }
  console.log('MEMORY_COMPARE=' + JSON.stringify(result))
  if (!result.pass) process.exitCode = 1
})().catch((error) => {
  console.error('MEMORY_COMPARE=FAIL', error)
  process.exitCode = 1
})
