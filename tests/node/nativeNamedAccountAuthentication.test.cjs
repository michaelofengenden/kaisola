const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { test } = require('node:test')

const root = path.resolve(__dirname, '../..')
const accounts = fs.readFileSync(
  path.join(root, 'native/KaisolaMac/Kaisola/Features/Settings/ProjectAccountsSection.swift'),
  'utf8',
)
const settings = fs.readFileSync(
  path.join(root, 'native/KaisolaMac/Kaisola/Features/Settings/SettingsView.swift'),
  'utf8',
)

test('named-account rows expose live status, verification detail, and the appropriate action', () => {
  const start = accounts.indexOf('private func accountRow(')
  const end = accounts.indexOf('\n    private func authenticationPresentation', start)
  assert.notEqual(start, -1)
  assert.notEqual(end, -1)
  const row = accounts.slice(start, end)

  assert.match(row, /Label\(authentication\.title, systemImage: authentication\.symbolName\)/u)
  assert.match(row, /Text\(authentication\.detail\(now: timeline\.date\)\)/u)
  assert.match(row, /Button\(authentication\.actionTitle\)/u)
  assert.match(row, /performAuthenticationAction\(authentication\.action, profile: profile\)/u)
  assert.doesNotMatch(row, /Button\("Sign In"\)/u)
})

test('account authentication refreshes on mount, workspace change, and sign-in completion', () => {
  assert.match(accounts, /\.onAppear \{[\s\S]*refreshAuthentication\(\)/u)
  assert.match(accounts, /\.onChange\(of: projectID\)[\s\S]*refreshAuthentication\(\)/u)
  assert.match(accounts, /AccountSignInSheet\(profile: profile\)[\s\S]*refreshAuthentication\(force: true\)/u)
  assert.match(settings, /ProjectAccountsSection\([\s\S]*workspace: workspace/u)
})
