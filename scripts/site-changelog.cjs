#!/usr/bin/env node
// Turns CHANGELOG.md into the site's changelog page. The file's structure is
// deliberately rigid (`## <semver> — <date>` headings, `- ` bullets, indented
// continuations), so this parser is small and FAILS LOUDLY on anything it
// does not recognize — a malformed heading must break the deploy, not ship a
// silently truncated page.
'use strict'

const fs = require('node:fs')
const path = require('node:path')

const HEADING = /^## (\d+\.\d+\.\d+) — (.+)$/

function escapeHtml(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

// Escape first, then style: `code` wins over **bold** inside it by running
// code first and bolding only outside backticks is overkill for this file's
// prose — entries use one or the other on a span, never nested.
function inline(text) {
  return escapeHtml(text)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
}

function renderChangelog(markdown) {
  const lines = markdown.split(/\r?\n/)
  const sections = []
  let current = null
  let bullet = null

  const flushBullet = () => {
    if (current && bullet !== null) current.bullets.push(bullet)
    bullet = null
  }

  for (const line of lines) {
    if (line.startsWith('## ')) {
      const match = HEADING.exec(line)
      if (!match) throw new Error(`unparseable changelog heading: ${line}`)
      flushBullet()
      current = { version: match[1], date: match[2], bullets: [], paragraphs: [] }
      sections.push(current)
      continue
    }
    if (line.startsWith('# ') || line.trim() === '') {
      flushBullet()
      continue
    }
    if (line.startsWith('- ')) {
      if (!current) throw new Error(`unexpected changelog line: ${line}`)
      flushBullet()
      bullet = line.slice(2)
      continue
    }
    if (/^\s+\S/.test(line) && bullet !== null) {
      bullet += ` ${line.trim()}`
      continue
    }
    // Plain prose inside a section (release notes occasionally carry a
    // paragraph, e.g. the version-restart note). Anything before the first
    // version heading is still a hard error.
    if (current && /^\S/.test(line)) {
      flushBullet()
      current.paragraphs.push(line.trim())
      continue
    }
    throw new Error(`unexpected changelog line: ${line}`)
  }
  flushBullet()

  const html = sections.map((section) => [
    '<section>',
    `<h2>${escapeHtml(section.version)} <time>${escapeHtml(section.date)}</time></h2>`,
    ...section.paragraphs.map((text) => `<p>${inline(text)}</p>`),
    ...(section.bullets.length
      ? ['<ul>', ...section.bullets.map((text) => `<li>${inline(text)}</li>`), '</ul>']
      : []),
    '</section>',
  ].join('\n')).join('\n')

  return { html, versions: sections.map((section) => section.version) }
}

function main() {
  const argument = (flag, fallback) => {
    const index = process.argv.indexOf(flag)
    return index >= 0 ? process.argv[index + 1] : fallback
  }
  const changelogPath = path.resolve(argument('--changelog', 'CHANGELOG.md'))
  const templatePath = path.resolve(argument('--template', 'site/changelog.template.html'))
  const outputPath = path.resolve(argument('--output', 'site/changelog.html'))

  const { html, versions } = renderChangelog(fs.readFileSync(changelogPath, 'utf8'))
  if (versions.length === 0) throw new Error('changelog produced no sections')
  const template = fs.readFileSync(templatePath, 'utf8')
  if (!template.includes('<!--CHANGELOG-->')) {
    throw new Error('template is missing the <!--CHANGELOG--> placeholder')
  }
  fs.writeFileSync(outputPath, template.replace('<!--CHANGELOG-->', html))
  console.log(`wrote ${outputPath} (${versions.length} versions, newest ${versions[0]})`)
}

if (require.main === module) main()

module.exports = { renderChangelog }
