// Repeatable, real-renderer Live Glass vs Eco memory comparison.
// Build first, then run: npm run memory:compare
const { spawn } = require('node:child_process')
const path = require('node:path')
const electron = require('electron')

const probe = path.join(__dirname, 'perfprobe.cjs')
const rounds = Math.max(1, Math.min(5, Number(process.env.KAISOLA_MEMORY_ROUNDS) || 2))

function run(variant) {
  return new Promise((resolve, reject) => {
    const child = spawn(electron, [probe, variant], { stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''
    child.stdout.on('data', (chunk) => { output += chunk; process.stdout.write(chunk) })
    child.stderr.on('data', (chunk) => { output += chunk; process.stderr.write(chunk) })
    child.on('error', reject)
    child.on('exit', (code) => {
      const match = [...output.matchAll(/PROBE_MEMORY=(\{[^\n]+\})/g)].at(-1)
      if (code !== 0 || !match) { reject(new Error(`Memory probe ${variant} failed (${code}).`)); return }
      try { resolve(JSON.parse(match[1])) } catch (error) { reject(error) }
    })
  })
}

;(async () => {
  const results = { E: [], G: [] }
  for (let i = 0; i < rounds; i++) {
    results.E.push(await run('E'))
    results.G.push(await run('G'))
  }
  const median = (rows) => {
    const sorted = rows.map((row) => row.medianMiB).sort((a, b) => a - b)
    const middle = Math.floor(sorted.length / 2)
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
  }
  const ecoMiB = median(results.E)
  const glassMiB = median(results.G)
  const pairedDeltasMiB = results.G.map((row, index) => Math.round((row.medianMiB - results.E[index].medianMiB) * 10) / 10)
  const deltaMiB = Math.round((pairedDeltasMiB.reduce((sum, value) => sum + value, 0) / pairedDeltasMiB.length) * 10) / 10
  const percent = ecoMiB > 0 ? Math.round(deltaMiB / ecoMiB * 1000) / 10 : 0
  console.log('MEMORY_COMPARE=' + JSON.stringify({ rounds, ecoMiB, glassMiB, deltaMiB, percent, pairedDeltasMiB, results }))
})().catch((error) => {
  console.error('MEMORY_COMPARE=FAIL', error)
  process.exitCode = 1
})
