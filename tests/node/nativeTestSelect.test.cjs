'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const repoRoot = path.resolve(__dirname, '..', '..')
const selector = require('../../scripts/native-test-select.cjs')
const timing = require('../../scripts/native-build-timing.cjs')

const inventory = selector.discoverInventory(repoRoot)

test('selection is deterministic regardless of changed-file order and duplicates', () => {
  const files = [
    'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift',
    'scripts/native-mcp-registry.cjs',
    'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift',
  ]
  const forward = selector.planForChanges(files, inventory)
  const reverse = selector.planForChanges([...files].reverse(), inventory)

  assert.deepEqual(reverse, forward)
  assert.deepEqual(forward.changedFiles, [
    'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift',
    'scripts/native-mcp-registry.cjs',
  ])
  assert.deepEqual(forward.native.selectors, [
    'CodeEditorViewTests', 'DataPreviewsTests', 'PDFPreviewBudgetTests',
    'SyntaxHighlighterTests', 'WorkspaceFilesTests',
  ])
  assert.deepEqual(forward.node.files, ['tests/node/nativeMcpRegistry.test.cjs'])
  assert.equal(forward.fallback, false)
})

test('a native test file selects exactly its test class', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/KaisolaTests/TerminalScrollPinTests.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, ['TerminalScrollPinTests'])
  assert.equal(plan.node.mode, 'none')
  assert.deepEqual(plan.swiftPackages, [])
})

test('terminal authority sources retain replay, input, and option-click contracts', () => {
  const expectations = [
    [
      'native/KaisolaMac/Kaisola/Features/Sessions/NativeTerminalSurface.swift',
      ['NativeTerminalInteractionTests', 'TerminalOptionClickTests', 'TerminalReplayFidelityTests'],
    ],
    [
      'native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift',
      ['SessionPaneLayoutTests', 'TerminalReplayFidelityTests'],
    ],
    [
      'native/KaisolaMac/Kaisola/Features/Sessions/TerminalSurfaceCache.swift',
      ['TerminalReplayFidelityTests'],
    ],
  ]

  for (const [file, required] of expectations) {
    const plan = selector.planForChanges([file], inventory)
    for (const testClass of required) {
      assert.ok(plan.native.selectors.includes(testClass), `${file} must select ${testClass}`)
    }
    assert.equal(plan.fallback, false)
  }
})

test('extracted workspace rail stays on the narrow workspace contract', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/Kaisola/Features/Workspace/WorkspaceRailView.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, ['WorkspaceFilesTests'])
  assert.equal(plan.node.mode, 'none')
})

test('agent file follow selects protocol, project, and workspace safety contracts', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/Kaisola/Features/Workspace/AgentFileFollow.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, [
    'AcpToolArtifactsTests', 'AppModelProjectContextTests', 'WorkspaceFilesTests',
  ])
  assert.equal(plan.node.mode, 'none')
  assert.equal(plan.fallback, false)
})

test('page-oriented transcript sources select persistence, paging, metadata, and restore contracts', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/Kaisola/Acp/AcpTranscriptStore.swift',
    'native/KaisolaMac/Kaisola/Acp/AcpConversation.swift',
    'native/KaisolaMac/Kaisola/Acp/AcpChatView.swift',
    'native/KaisolaMac/Kaisola/App/NativePreviewPaths.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, [
    'AcpAttachmentsTests', 'AcpClientTests', 'AcpToolArtifactsTests',
    'AcpTranscriptPagingTests', 'AcpTranscriptStoreTests',
    'AppModelProjectContextTests', 'NativePreviewSettingsTests', 'UsageCenterTests',
  ])
  assert.equal(plan.node.mode, 'none')
  assert.equal(plan.fallback, false)
})

test('settings surfaces stay on their bounded account and configuration contracts', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/Kaisola/Features/Settings/ApiKeysSettingsTab.swift',
    'native/KaisolaMac/Kaisola/Features/Settings/ProjectAccountsSection.swift',
    'native/KaisolaMac/Kaisola/Features/Settings/SettingsView.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, [
    'ApiKeyStoreTests', 'AppModelProjectContextTests',
    'CommandRegistryTests', 'CompanionConnectionSessionTests', 'McpConfigStoreTests',
    'NativePreviewSettingsTests', 'NativeUpdateConfigurationTests',
    'NotificationBridgeTests', 'UsageCenterTests',
  ])
  assert.equal(plan.node.mode, 'none')
  assert.equal(plan.fallback, false)
})

test('operational onboarding stays on readiness and account contracts', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/Kaisola/Features/Onboarding/OnboardingView.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, [
    'CommandRegistryTests', 'OnboardingStateTests', 'UsageCenterTests',
  ])
  assert.equal(plan.node.mode, 'none')
  assert.equal(plan.fallback, false)
})

test('typed command surfaces select the command registry contract', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/Kaisola/Features/Palette/CommandPaletteView.swift',
    'native/KaisolaMac/Kaisola/Features/Palette/CommandRegistry.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, ['CommandRegistryTests', 'FuzzyMatchTests'])
  assert.equal(plan.node.mode, 'none')
  assert.equal(plan.fallback, false)
})

test('extracted preview units retain the complete preview contract lane', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewContent.swift',
    'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewEditors.swift',
    'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewRecovery.swift',
    'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewTabs.swift',
    'native/KaisolaMac/Kaisola/Features/Workspace/MarkdownAssets.swift',
    'native/KaisolaMac/Kaisola/Features/Workspace/MarkdownPreview.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, [
    'DataPreviewsTests', 'PDFPreviewBudgetTests', 'SyntaxHighlighterTests', 'WorkspaceFilesTests',
  ])
  assert.equal(plan.node.mode, 'none')
  assert.equal(plan.fallback, false)
})

test('confined editor sources select bridge, bundle, and workspace contracts', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/Kaisola/Features/Workspace/CodeEditorView.swift',
    'native/KaisolaMac/Kaisola/Features/Workspace/SourceOutline.swift',
    'native/KaisolaMac/Kaisola/Resources/CodeEditor/index.html',
    'scripts/code-editor/editor.mjs',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, ['CodeEditorViewTests', 'WorkspaceFilesTests'])
  assert.deepEqual(plan.node.files, ['tests/node/codeEditorBundle.test.cjs'])
  assert.equal(plan.fallback, false)
})

test('custom ACP containment sources select launch and approval contracts', () => {
  const plan = selector.planForChanges([
    'native/KaisolaMac/Kaisola/Acp/AcpAdapterResolver.swift',
    'native/KaisolaMac/Kaisola/Acp/AdapterInstallManager.swift',
    'native/KaisolaMac/Kaisola/Acp/CustomAdapterContainment.swift',
    'native/KaisolaMac/Kaisola/Broker/CustomAgentStore.swift',
    'native/KaisolaMac/Kaisola/Features/Settings/CustomAgentsSection.swift',
  ], inventory)

  assert.equal(plan.native.mode, 'focused')
  assert.deepEqual(plan.native.selectors, ['AcpClientTests', 'CustomAgentStoreTests'])
  assert.equal(plan.node.mode, 'none')
  assert.equal(plan.fallback, false)
})

test('extension registry persistence and settings retain recovery contracts', () => {
  const expectations = [
    [
      'native/KaisolaMac/Kaisola/Features/Sessions/CustomThemeStore.swift',
      ['ExtensionsSettingsHubTests', 'TerminalThemeRegistryTests'],
    ],
    [
      'native/KaisolaMac/Kaisola/Features/Workspace/CustomGrammarStore.swift',
      ['CustomGrammarRegistryTests', 'ExtensionsSettingsHubTests', 'SyntaxHighlighterTests'],
    ],
    [
      'native/KaisolaMac/Kaisola/Features/Settings/ExtensionsSettingsHub.swift',
      ['ExtensionsSettingsHubTests'],
    ],
    [
      'native/KaisolaMac/Kaisola/Features/Settings/ExtensionsSettingsModel.swift',
      ['ExtensionsSettingsHubTests'],
    ],
  ]

  for (const [file, selectors] of expectations) {
    const plan = selector.planForChanges([file], inventory)
    assert.equal(plan.native.mode, 'focused')
    assert.deepEqual(plan.native.selectors, selectors)
    assert.equal(plan.node.mode, 'none')
    assert.equal(plan.fallback, false)
  }
})

test('broker and shared wire changes expand to the reproducible contract lane', () => {
  const plan = selector.planForChanges([
    'runtime/node-broker/ipc/brokerWire.cjs',
  ], inventory)

  assert.equal(plan.native.mode, 'contract')
  assert.deepEqual(plan.native.selectors, [...selector.NATIVE_CONTRACT_TESTS].sort())
  assert.equal(plan.node.mode, 'all')
  assert.deepEqual(plan.swiftPackages, ['native/KaisolaCore'])
  assert.equal(plan.fallback, false)
  assert.match(plan.reasons.join('\n'), /broker\/shared protocol changed/u)
})

test('Swift broker core and executable changes use the broker contract lane without fallback', () => {
  for (const file of [
    'native/KaisolaMac/KaisolaSessionBrokerCore/ShadowBrokerConfiguration.swift',
    'native/KaisolaMac/KaisolaSessionBrokerCore/BrokerServer.swift',
    'native/KaisolaMac/KaisolaSessionBroker/KaisolaSessionBrokerMain.swift',
  ]) {
    const plan = selector.planForChanges([file], inventory)
    assert.equal(plan.native.mode, 'contract', file)
    assert.ok(plan.native.selectors.includes('SwiftSessionBrokerConfigurationTests'), file)
    assert.ok(plan.native.selectors.includes('SwiftSessionBrokerCoreTests'), file)
    assert.ok(plan.native.selectors.includes('SwiftSessionBrokerDarwinPTYTests'), file)
    assert.ok(plan.native.selectors.includes('SwiftSessionBrokerFreshEndToEndTests'), file)
    assert.ok(plan.native.selectors.includes('SwiftSessionBrokerFreshStoreTests'), file)
    assert.ok(plan.native.selectors.includes('SwiftSessionBrokerFreshWireTests'), file)
    assert.ok(plan.native.selectors.includes('SwiftSessionBrokerOutputTests'), file)
    assert.ok(plan.native.selectors.includes('SwiftSessionBrokerShadowIntegrationTests'), file)
    assert.equal(plan.node.mode, 'all', file)
    assert.deepEqual(plan.swiftPackages, ['native/KaisolaCore'], file)
    assert.equal(plan.fallback, false, file)
  }
})

test('release changes select all Node contracts plus update-facing native tests', () => {
  const plan = selector.planForChanges(['scripts/native-appcast.cjs'], inventory)

  assert.equal(plan.node.mode, 'all')
  assert.deepEqual(plan.native.selectors, [
    'BrokerHelperPackageTests', 'NativeUpdateConfigurationTests',
  ])
  assert.equal(plan.fallback, false)
})

test('an unmapped runtime change uses the broad fallback rather than skipping', () => {
  const plan = selector.planForChanges(['unexpected/runtime-policy.toml'], inventory)

  assert.equal(plan.fallback, true)
  assert.equal(plan.node.mode, 'all')
  assert.equal(plan.native.mode, 'contract')
  assert.deepEqual(plan.native.selectors, [...selector.NATIVE_CONTRACT_TESTS].sort())
  assert.deepEqual(plan.swiftPackages, ['native/KaisolaCore'])
})

test('known documentation-only changes produce an explicit empty runtime plan', () => {
  const plan = selector.planForChanges(['docs/fast-loop.md', 'README.md'], inventory)

  assert.equal(plan.fallback, false)
  assert.equal(plan.node.mode, 'none')
  assert.equal(plan.native.mode, 'none')
  assert.deepEqual(plan.swiftPackages, [])
  assert.deepEqual(plan.reasons, ['known documentation-only change'])
})

test('repository-relative path normalization is strict', () => {
  assert.equal(selector.normalizeChangedFile('./native\\KaisolaMac\\project.yml'), 'native/KaisolaMac/project.yml')
  assert.throws(() => selector.normalizeChangedFile('../outside.swift'), /repository-relative/u)
  assert.throws(() => selector.normalizeChangedFile('/tmp/outside.swift'), /repository-relative/u)
})

test('CLI accepts explicit files and emits the same machine-readable plan', () => {
  const script = path.join(repoRoot, 'scripts', 'native-test-select.cjs')
  const result = spawnSync(process.execPath, [
    script,
    '--changed-file', 'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift',
    '--format', 'json',
  ], { cwd: repoRoot, encoding: 'utf8' })

  assert.equal(result.status, 0, result.stderr)
  const plan = JSON.parse(result.stdout)
  assert.deepEqual(plan.native.selectors, [
    'CodeEditorViewTests', 'DataPreviewsTests', 'PDFPreviewBudgetTests',
    'SyntaxHighlighterTests', 'WorkspaceFilesTests',
  ])
  assert.equal(plan.node.mode, 'none')
})

test('CLI rejects an empty explicit changed-file list instead of skipping tests', () => {
  const script = path.join(repoRoot, 'scripts', 'native-test-select.cjs')
  const result = spawnSync(process.execPath, [
    script, '--changed-files-from', '-', '--format', 'json',
  ], { cwd: repoRoot, input: '', encoding: 'utf8' })

  assert.equal(result.status, 2)
  assert.match(result.stderr, /no changed files/u)
})

test('changed-file runner prints a plan without invoking xcodebuild in dry-run mode', () => {
  const script = path.join(repoRoot, 'scripts', 'native-test-changed.sh')
  const result = spawnSync(script, [
    '--changed-file', 'native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift',
    '--dry-run',
  ], { cwd: repoRoot, encoding: 'utf8' })

  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /Native tests \(focused\): CodeEditorViewTests, DataPreviewsTests, PDFPreviewBudgetTests, SyntaxHighlighterTests, WorkspaceFilesTests/u)
  assert.match(result.stdout, /Dry run: no tests executed/u)
})

test('changed-file runner isolates SwiftPM caches from repository moves', () => {
  const runner = fs.readFileSync(path.join(repoRoot, 'scripts', 'native-test-changed.sh'), 'utf8')
  assert.match(runner, /shasum -a 256/)
  assert.match(runner, /--scratch-path "\$package_scratch"/)
})

test('changed-file runner executes a focused Node file from its JSON plan', () => {
  const script = path.join(repoRoot, 'scripts', 'native-test-changed.sh')
  const result = spawnSync(script, [
    '--changed-file', 'tests/node/nativeCatalogSmoke.test.cjs',
  ], { cwd: repoRoot, encoding: 'utf8' })

  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /Node tests \(focused\): tests\/node\/nativeCatalogSmoke\.test\.cjs/u)
  assert.match(result.stdout, /Changed-file test lane passed/u)
})

test('build timing arguments require a bounded warm-run count and a label', () => {
  const parsed = timing.parseArguments(['--label', 'after-split', '--warm-runs', '2'])
  assert.equal(parsed.label, 'after-split')
  assert.equal(parsed.warmRuns, 2)
  assert.throws(() => timing.parseArguments([]), /--label is required/u)
  assert.throws(
    () => timing.parseArguments(['--label', 'bad', '--warm-runs', '0']),
    /integer from 1 through 10/u,
  )
})

test('build timing cleanup refuses paths outside its exact temporary namespace', () => {
  assert.throws(() => timing.safeCleanup(repoRoot), /refusing to remove unexpected timing directory/u)
})

test('fast build refuses contradictory helper options before touching the build cache', () => {
  const script = path.join(repoRoot, 'scripts', 'native-fast.sh')
  const result = spawnSync(script, [
    '--build-only', '--refresh-helper', '--skip-helper',
  ], { cwd: repoRoot, encoding: 'utf8' })

  assert.equal(result.status, 2)
  assert.match(result.stderr, /mutually exclusive/u)
})

test('helper skipping is restricted to the isolated timing runner', () => {
  const script = path.join(repoRoot, 'scripts', 'native-fast.sh')
  const result = spawnSync(script, [
    '--build-only', '--skip-helper',
  ], { cwd: repoRoot, encoding: 'utf8' })

  assert.equal(result.status, 2)
  assert.match(result.stderr, /reserved for the isolated native:timing runner/u)
})
