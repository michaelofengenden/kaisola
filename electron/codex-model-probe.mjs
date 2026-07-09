// Read-only app-server probe: prints the exact model/effort catalog exposed by
// the installed Codex binary. It never starts a thread or sends a prompt.
import { spawn } from 'node:child_process'
import readline from 'node:readline'

const executable = process.env.CODEX_BIN || 'codex'
const child = spawn(executable, ['-s', 'read-only', '-a', 'untrusted', 'app-server'], {
  env: process.env,
  stdio: ['pipe', 'pipe', 'pipe'],
})
child.stderr.on('data', (data) => process.stderr.write(data))
child.on('error', (error) => {
  console.error(error.message)
  process.exitCode = 1
})

const send = (id, method, params = {}) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
const notify = (method, params = {}) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n')
const lines = readline.createInterface({ input: child.stdout })
const timer = setTimeout(() => {
  console.error('Codex model probe timed out.')
  child.kill('SIGKILL')
  process.exitCode = 1
}, 20_000)
timer.unref?.()

lines.on('line', (line) => {
  let message
  try { message = JSON.parse(line) } catch { return }
  if (message.id === 1) {
    if (message.error) throw new Error(message.error.message)
    notify('initialized')
    send(2, 'model/list', { includeHidden: true, limit: 100 })
  } else if (message.id === 2) {
    clearTimeout(timer)
    if (message.error) {
      console.error(message.error.message)
      process.exitCode = 1
    } else {
      const models = message.result?.data || message.result?.models || []
      console.log(JSON.stringify(models.map((model) => ({
        id: model.id || model.model,
        name: model.displayName || model.display_name,
        defaultEffort: model.defaultReasoningEffort || model.default_reasoning_effort,
        efforts: model.supportedReasoningEfforts || model.supported_reasoning_efforts || model.supportedReasoningLevels,
      })), null, 2))
    }
    child.kill()
  }
})

send(1, 'initialize', { clientInfo: { name: 'kaisola-probe', title: 'Kaisola model probe', version: '0' } })
