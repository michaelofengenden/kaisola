'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { renderChangelog } = require('../../scripts/site-changelog.cjs')

const FIXTURE = `# Changelog

## 0.2.0 — 2026-08-08

- Panes hide from a **minus** at their own top-right.
- The \`Kaisola.dmg\` link is permanent & stable.

## 0.1.9 — 2026-08-01

- One entry with <angle brackets> that must not become markup.
`

test('renders every version newest-first with escaped, inline-styled bullets', () => {
  const { html, versions } = renderChangelog(FIXTURE)
  assert.deepEqual(versions, ['0.2.0', '0.1.9'])
  const first = html.indexOf('0.2.0')
  const second = html.indexOf('0.1.9')
  assert.ok(first >= 0 && second > first, 'versions appear in file order')
  assert.ok(html.includes('<time'), 'dates are marked up')
  assert.ok(html.includes('<strong>minus</strong>'), 'bold renders')
  assert.ok(html.includes('<code>Kaisola.dmg</code>'), 'code renders')
  assert.ok(html.includes('&amp; stable'), 'ampersands escape')
  assert.ok(html.includes('&lt;angle brackets&gt;'), 'angle brackets escape')
  assert.ok(!/<(?!\/?(section|h2|ul|li|time|strong|code)\b)/.test(html),
    'only the expected tags appear')
})

test('a heading that is not a version fails loudly', () => {
  assert.throws(
    () => renderChangelog('# Changelog\n\n## not-a-version\n\n- entry\n'),
    /unparseable changelog heading/
  )
})

test('prose paragraphs inside a section render as paragraphs', () => {
  const { html } = renderChangelog(
    '# Changelog\n\n## 0.1.0 — 2026-01-01\n\nVersion numbers restart here.\n\n- An entry.\n'
  )
  assert.ok(html.includes('<p>Version numbers restart here.</p>'))
})

test('content before any version section fails loudly', () => {
  assert.throws(
    () => renderChangelog('# Changelog\n\nA stray preamble paragraph.\n\n## 0.1.0 — 2026-01-01\n\n- entry\n'),
    /unexpected changelog line/
  )
})
