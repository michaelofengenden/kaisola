// Read-only integration probe for the App-Server-based Codex ACP adapter.
// It creates a session, selects GPT-5.6 Sol + Ultra, and exits without a prompt.
const path = require('node:path')
const { AcpConnection } = require('./ipc/acp.cjs')

const adapter = path.join(__dirname, '..', 'node_modules', '@agentclientprotocol', 'codex-acp', 'dist', 'index.js')
const codex = process.env.CODEX_PATH || 'codex'
const notices = []
const connection = new AcpConnection(
  {
    command: process.execPath,
    args: [adapter],
    env: { CODEX_PATH: codex },
    cwd: path.join(__dirname, '..'),
    mcpServers: [],
  },
  {
    onNotice: (notice) => notices.push(notice),
    onPermission: async () => 'cancel',
    fsGuard: () => false,
  },
)

const timeout = setTimeout(() => {
  console.error('CODEX_ACP_PROBE=TIMEOUT', JSON.stringify(notices.slice(-5)))
  connection.dispose()
  process.exit(1)
}, 30_000)

;(async () => {
  try {
    connection.start()
    await connection.initialize()
    const session = await connection.newSession()
    const controls = connection.getControls()
    console.log('CODEX_ACP_CONTROLS=' + JSON.stringify(controls))
    const model = controls.configOptions?.find((option) => option.id === 'model' || option.category === 'model')
    const effort = controls.configOptions?.find((option) => /effort|reason/i.test(`${option.id} ${option.name} ${option.category}`))
    const sol = model?.options?.find((option) => /gpt-5\.6-sol/i.test(String(option.value)))
    const ultra = effort?.options?.find((option) => option.value === 'ultra')
    if (!sol || !ultra) throw new Error(`Missing Sol/Ultra controls for session ${session.sessionId}`)
    await connection.setConfigOption(model.id, sol.value)
    await connection.setConfigOption(effort.id, ultra.value)
    console.log('CODEX_ACP_ULTRA=PASS')
    const luna = model.options.find((option) => /gpt-5\.6-luna/i.test(String(option.value)))
    if (luna) {
      await connection.setConfigOption(model.id, luna.value)
      await new Promise((resolve) => setTimeout(resolve, 250))
      const lunaEffort = connection.getControls().configOptions?.find((option) => /effort|reason/i.test(`${option.id} ${option.name} ${option.category}`))
      if (!lunaEffort?.options?.some((option) => option.value === 'max') || lunaEffort.options.some((option) => option.value === 'ultra')) {
        throw new Error('Luna effort catalog did not reconcile to max-without-ultra')
      }
      await connection.setConfigOption(lunaEffort.id, 'max')
      console.log('CODEX_ACP_MODEL_RECONCILE=PASS wire=max')
    }
  } catch (error) {
    console.error('CODEX_ACP_ULTRA=FAIL', error.message, JSON.stringify(notices.slice(-5)))
    process.exitCode = 1
  } finally {
    clearTimeout(timeout)
    connection.dispose()
  }
})()
