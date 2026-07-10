// Package outside ~/Documents, where modern macOS continuously re-applies
// com.apple.provenance to Mach-O files and can race electron-builder's signer.
// Only finished archives/manifests come back into release/; the signed .app is
// verified before it leaves the unprotected staging directory.
const { spawnSync } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const yaml = require('js-yaml')
const { buildBlockMap } = require('app-builder-lib/out/targets/blockmap/blockmap.js')

const root = path.join(__dirname, '..')
const release = path.join(root, 'release')
const args = process.argv.slice(2)
const builder = path.join(root, 'node_modules', '.bin', process.platform === 'win32' ? 'electron-builder.cmd' : 'electron-builder')

function run(command, commandArgs, options = {}) {
  const result = spawnSync(command, commandArgs, { cwd: root, stdio: 'inherit', ...options })
  if (result.error) throw result.error
  if (result.status !== 0) process.exit(result.status ?? 1)
}

async function main() {
  if (process.platform !== 'darwin') {
    run(builder, args)
    return
  }

  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-builder-'))
  let complete = false
  try {
    run(builder, [...args, `--config.directories.output=${stage}`])
    const app = path.join(stage, 'mac-arm64', 'Kaisola.app')
    if (fs.existsSync(app)) {
      run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', app])

      // electron-builder's archive helper can discard metadata that a nested
      // macOS code signature covers. Recreate the updater ZIP with ditto so
      // resource forks and extended attributes survive extraction.
      const zipName = fs.readdirSync(stage).find((name) => name.endsWith('-mac.zip'))
      if (zipName) {
        const zip = path.join(stage, zipName)
        const blockmap = `${zip}.blockmap`
        fs.rmSync(zip, { force: true })
        fs.rmSync(blockmap, { force: true })
        run('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, zip])
        const zipInfo = await buildBlockMap(zip, 'gzip', blockmap)

        const manifestPath = path.join(stage, 'latest-mac.yml')
        const manifest = yaml.load(fs.readFileSync(manifestPath, 'utf8'))
        const zipEntry = manifest.files?.find((file) => file.url === zipName)
        if (!zipEntry) throw new Error(`Updater manifest is missing ${zipName}`)
        zipEntry.sha512 = zipInfo.sha512
        zipEntry.size = zipInfo.size
        if (manifest.path === zipName) {
          manifest.sha512 = zipInfo.sha512
        }
        fs.writeFileSync(manifestPath, yaml.dump(manifest, { lineWidth: -1, noRefs: true }))

        const verification = path.join(stage, 'zip-verification')
        fs.mkdirSync(verification)
        run('/usr/bin/ditto', ['-x', '-k', zip, verification])
        run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', path.join(verification, 'Kaisola.app')])
        fs.rmSync(verification, { recursive: true, force: true })
      }
    }

    fs.mkdirSync(release, { recursive: true })
    for (const entry of fs.readdirSync(stage, { withFileTypes: true })) {
      if (!entry.isFile()) continue // never copy the unpacked .app into Documents
      const from = path.join(stage, entry.name)
      const to = path.join(release, entry.name)
      fs.copyFileSync(from, to)
    }
    complete = true
  } finally {
    if (complete || process.env.KAISOLA_KEEP_PACKAGE_STAGE !== '1') {
      fs.rmSync(stage, { recursive: true, force: true })
    } else {
      console.error(`Packaging stage retained for inspection: ${stage}`)
    }
  }
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
