// The one atomic private-file write used by every handler that persists
// sensitive state (keys, identities, catalogs, archives). Temp file created
// 0o600 in the target directory, renamed into place so a crash mid-write can
// never truncate the destination, temp cleaned up on error.
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')

function writePrivateFile(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const temp = `${file}.tmp.${process.pid}.${Date.now()}.${crypto.randomBytes(4).toString('hex')}`
  try {
    fs.writeFileSync(temp, data, { mode: 0o600 })
    // An existing file can have inherited permissive bits; rename preserves the
    // freshly-created temp file's private mode on POSIX.
    try { fs.chmodSync(temp, 0o600) } catch { /* Windows / restrictive FS */ }
    fs.renameSync(temp, file)
    try { fs.chmodSync(file, 0o600) } catch { /* Windows / restrictive FS */ }
  } catch (err) {
    try { fs.unlinkSync(temp) } catch { /* no temp / already renamed */ }
    throw err
  }
}

function writePrivateJson(file, data) {
  writePrivateFile(file, JSON.stringify(data, null, 2))
}

module.exports = { writePrivateFile, writePrivateJson }
