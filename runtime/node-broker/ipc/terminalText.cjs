'use strict'

const os = require('node:os')

const UNSAFE_TERMINAL_TEXT = /[\p{Cc}\p{Zl}\p{Zp}\u061c\u200e\u200f\u202a-\u202e\u2066-\u206f\ufeff]/gu

/** Keep untrusted paths readable without letting terminal controls, invisible
 * line breaks, or bidi state alter the warning around them. */
function escapeTerminalText(value) {
  return String(value).replace(UNSAFE_TERMINAL_TEXT, (character) => {
    const codePoint = character.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')
    return `\\u{${codePoint}}`
  })
}

function missingCwdWarning(cwd, home = os.homedir()) {
  const safeCwd = escapeTerminalText(cwd)
  const safeHome = escapeTerminalText(home)
  return `\r\n\x1b[33m⚠ working directory not found:\x1b[0m ${safeCwd}\r\n\x1b[33m  started in ${safeHome} instead — this session is NOT isolated.\x1b[0m\r\n\r\n`
}

module.exports = { escapeTerminalText, missingCwdWarning }
