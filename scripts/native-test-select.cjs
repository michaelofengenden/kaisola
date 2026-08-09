#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const repoRoot = path.resolve(__dirname, '..')

const NATIVE_CONTRACT_TESTS = Object.freeze([
  'AppModelProjectContextTests',
  'BrokerControlClientTests',
  'BrokerHelperPackageTests',
  'BrokerLaunchConfigurationTests',
  'BrokerModelsTests',
  'BrokerStartupCoordinatorTests',
  'NativeUpdateConfigurationTests',
  'ObserveOnlyBrokerClientTests',
  'TerminalLinkRoutingTests',
  'WorkspaceFilesTests',
])

const NATIVE_DIRECTORY_TESTS = Object.freeze([
  ['native/KaisolaMac/Kaisola/Acp/', [
    'AcpClientTests', 'AcpPermissionRulesTests', 'AcpTerminalHostTests',
    'AcpTranscriptStoreTests', 'AcpToolArtifactsTests',
  ]],
  ['native/KaisolaMac/Kaisola/App/', [
    'AppModelProjectContextTests', 'AppModelReconnectTests',
    'NativePreviewSettingsTests', 'NotificationBridgeTests',
  ]],
  ['native/KaisolaMac/Kaisola/Broker/', [
    'BrokerControlClientTests', 'BrokerDiscoveryTests', 'BrokerModelsTests',
    'BrokerReconnectBackoffTests', 'BrokerStartupCoordinatorTests',
    'ObserveOnlyBrokerClientTests', 'ObserveOnlyBrokerHistoryPagingTests',
    'TerminalCursorStoreTests',
  ]],
  ['native/KaisolaMac/Kaisola/Companion/', [
    'CompanionCommandRouterTests', 'CompanionConnectionSessionTests',
    'CompanionProjectionBuilderTests', 'CompanionTerminalControlTests',
    'CompanionTerminalStreamHubTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Palette/', [
    'CommandRegistryTests', 'FuzzyMatchTests', 'OmniBarDispatchTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Onboarding/', [
    'OnboardingStateTests', 'UsageCenterTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Settings/', [
    'ApiKeyStoreTests', 'AppModelProjectContextTests',
    'CommandRegistryTests', 'CompanionConnectionSessionTests', 'McpConfigStoreTests',
    'NativePreviewSettingsTests', 'NativeUpdateConfigurationTests',
    'NotificationBridgeTests', 'UsageCenterTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Sessions/', [
    'NativeTerminalInteractionTests', 'SessionPaneLayoutTests',
    'TerminalDocumentTests', 'TerminalLinkRoutingTests', 'TerminalScrollPinTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Workspace/', [
    'DataPreviewsTests', 'LocalhostDetectorTests', 'QuickActionStoreTests',
    'SyntaxHighlighterTests', 'WorkspaceFilesTests', 'WorkspaceWatcherTests',
  ]],
  ['native/KaisolaMac/Kaisola/Git/', ['GitPRTests', 'GitPanelModelTests', 'GitServiceTests']],
  ['native/KaisolaMac/Kaisola/Mesh/', [
    'MeshColumnDeckTests', 'MeshSessionTests', 'MeshStagedTests',
  ]],
  ['native/KaisolaMac/Kaisola/Updates/', [
    'NativeUpdateConfigurationTests', 'BrokerHelperPackageTests',
  ]],
])

const FILE_PREVIEW_TESTS = Object.freeze([
  'DataPreviewsTests', 'SyntaxHighlighterTests', 'WorkspaceFilesTests',
])

const CODE_EDITOR_TESTS = Object.freeze([
  'CodeEditorViewTests', 'WorkspaceFilesTests',
])

const NATIVE_FILE_TESTS = Object.freeze(new Map([
  ['native/KaisolaMac/Kaisola/Acp/AcpTranscriptStore.swift', [
    'AcpTranscriptStoreTests', 'AppModelProjectContextTests', 'UsageCenterTests',
  ]],
  ['native/KaisolaMac/Kaisola/Acp/AcpConversation.swift', [
    'AcpAttachmentsTests', 'AcpClientTests', 'AcpToolArtifactsTests',
    'AcpTranscriptPagingTests',
  ]],
  ['native/KaisolaMac/Kaisola/Acp/AcpChatView.swift', [
    'AcpTranscriptPagingTests',
  ]],
  ['native/KaisolaMac/Kaisola/Acp/AcpClient.swift', [
    'AcpAttachmentsTests', 'AcpClientTests',
  ]],
  ['native/KaisolaMac/Kaisola/App/NativePreviewPaths.swift', [
    'AcpTranscriptStoreTests', 'NativePreviewSettingsTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Onboarding/OnboardingView.swift', [
    'CommandRegistryTests', 'OnboardingStateTests', 'UsageCenterTests',
  ]],
  ['native/KaisolaMac/Kaisola/App/KaisolaMacAppDelegate.swift', [
    'CommandRegistryTests', 'NativePreviewSettingsTests', 'NativeTerminalInteractionTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Palette/CommandPaletteView.swift', [
    'CommandRegistryTests', 'FuzzyMatchTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Palette/CommandRegistry.swift', [
    'CommandRegistryTests',
  ]],
  ['native/KaisolaMac/Kaisola/App/AppModel.swift', [
    'AppModelBrokerFallbackTests', 'AppModelProjectContextTests',
    'AppModelReconnectTests', 'AppModelTerminalRetentionTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Sessions/NativeTerminalSurface.swift', [
    'NativeTerminalInteractionTests', 'SwiftTermStressTests',
    'TerminalReplayFidelityTests', 'TerminalScrollPinTests',
    'TerminalScrollbackDepthTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift', [
    'AppModelProjectContextTests', 'CommandRegistryTests', 'NativePreviewSettingsTests',
    'SessionPaneLayoutTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Workspace/BrowserCardView.swift', [
    'AppModelProjectContextTests', 'LocalhostDetectorTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Workspace/AgentFileFollow.swift', [
    'AcpToolArtifactsTests', 'AppModelProjectContextTests', 'WorkspaceFilesTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewContent.swift', FILE_PREVIEW_TESTS],
  ['native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewEditors.swift', FILE_PREVIEW_TESTS],
  ['native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewRecovery.swift', FILE_PREVIEW_TESTS],
  ['native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewTabs.swift', FILE_PREVIEW_TESTS],
  ['native/KaisolaMac/Kaisola/Features/Workspace/CodeEditorView.swift', CODE_EDITOR_TESTS],
  ['native/KaisolaMac/Kaisola/Features/Workspace/SourceOutline.swift', CODE_EDITOR_TESTS],
  ['native/KaisolaMac/Kaisola/Features/Workspace/FilePreviewView.swift', [
    ...FILE_PREVIEW_TESTS, 'CodeEditorViewTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Workspace/MarkdownAssets.swift', FILE_PREVIEW_TESTS],
  ['native/KaisolaMac/Kaisola/Features/Workspace/MarkdownPreview.swift', FILE_PREVIEW_TESTS],
  ['native/KaisolaMac/Kaisola/Features/Workspace/FileTreeModel.swift', [
    'WorkspaceFilesTests', 'WorkspaceWatcherTests',
  ]],
  ['native/KaisolaMac/Kaisola/Features/Workspace/WorkspaceRailView.swift', [
    'WorkspaceFilesTests',
  ]],
]))

const RELEASE_NODE_TESTS = Object.freeze([
  'tests/node/nativeAppcast.test.cjs',
  'tests/node/nativeBrokerPackage.test.cjs',
  'tests/node/nativeDistributionSign.test.cjs',
  'tests/node/nativeReleasePreflight.test.cjs',
])

function normalizeChangedFile(value) {
  if (typeof value !== 'string') throw new TypeError('changed file must be a string')
  const normalized = value.trim().replaceAll('\\', '/').replace(/^\.\//, '')
  if (!normalized) return null
  if (path.posix.isAbsolute(normalized) || normalized === '..' || normalized.startsWith('../')) {
    throw new Error(`changed file must be repository-relative: ${value}`)
  }
  return path.posix.normalize(normalized)
}

function uniqueSorted(values) {
  return [...new Set(values)].sort((left, right) => left.localeCompare(right, 'en'))
}

function discoverInventory(root = repoRoot) {
  const nativeTestsDirectory = path.join(root, 'native', 'KaisolaMac', 'KaisolaTests')
  const nodeTestsDirectory = path.join(root, 'tests', 'node')
  const nativeTestClasses = fs.existsSync(nativeTestsDirectory)
    ? fs.readdirSync(nativeTestsDirectory)
      .filter((name) => name.endsWith('Tests.swift'))
      .map((name) => name.slice(0, -'.swift'.length))
      .sort()
    : []
  const nodeTestFiles = fs.existsSync(nodeTestsDirectory)
    ? fs.readdirSync(nodeTestsDirectory)
      .filter((name) => name.endsWith('.test.cjs'))
      .map((name) => `tests/node/${name}`)
      .sort()
    : []
  return { nativeTestClasses, nodeTestFiles }
}

function addExistingNativeTests(plan, requested, inventory, reason) {
  const available = new Set(inventory.nativeTestClasses)
  const missing = requested.filter((selector) => !available.has(selector))
  if (missing.length) {
    throw new Error(`test selection policy references missing native tests: ${missing.join(', ')}`)
  }
  for (const selector of requested) plan.nativeSelectors.add(selector)
  plan.reasons.add(reason)
}

function addExistingNodeTests(plan, requested, inventory, reason) {
  const available = new Set(inventory.nodeTestFiles)
  const missing = requested.filter((file) => !available.has(file))
  if (missing.length) {
    throw new Error(`test selection policy references missing Node tests: ${missing.join(', ')}`)
  }
  for (const file of requested) plan.nodeFiles.add(file)
  plan.reasons.add(reason)
}

function matchingNativeTests(sourceFile, inventory) {
  const stem = path.posix.basename(sourceFile, path.posix.extname(sourceFile))
  const normalizedStem = stem.replace(/(?:View|Model|Store|Service|Controller|Coordinator|Client|Handler)$/u, '')
  return inventory.nativeTestClasses.filter((testClass) => {
    const testStem = testClass.replace(/Tests$/u, '')
    return testStem === stem
      || testStem.startsWith(stem)
      || (normalizedStem.length >= 5 && testStem.startsWith(normalizedStem))
  })
}

function nodeTestForScript(sourceFile, inventory) {
  const stem = path.posix.basename(sourceFile, path.posix.extname(sourceFile))
  const camelStem = stem.replace(/-([a-z0-9])/gu, (_, letter) => letter.toUpperCase())
  const exact = `tests/node/${camelStem}.test.cjs`
  return inventory.nodeTestFiles.includes(exact) ? [exact] : []
}

function isKnownNonRuntimeFile(file) {
  return /^(?:docs\/|.*\.md$|LICENSE(?:\.|$)|\.gitignore$)/u.test(file)
}

function isReleaseFile(file) {
  return file === 'package.json'
    || file === 'package-lock.json'
    || file.startsWith('.github/workflows/release')
    || /^scripts\/(?:native-(?:appcast|distribution-sign|release-preflight)|release-fast)\.cjs$/u.test(file)
}

function isBrokerOrSharedProtocolFile(file) {
  return file.startsWith('runtime/node-broker/')
    || file.startsWith('protocol/broker/')
    || file.startsWith('native/KaisolaCore/Sources/KaisolaBrokerProtocol/')
    || file.startsWith('native/KaisolaMac/BrokerBootstrap/')
    || file.startsWith('native/KaisolaMac/BrokerHelper/')
    || file.startsWith('native/KaisolaMac/Shared/Broker')
    || file === 'scripts/native-broker-package.cjs'
}

function createMutablePlan() {
  return {
    nativeSelectors: new Set(),
    nodeFiles: new Set(),
    runAllNodeTests: false,
    runCoreTests: false,
    contractLane: false,
    fallback: false,
    reasons: new Set(),
  }
}

function applyBroadFallback(plan, inventory, reason) {
  plan.fallback = true
  plan.contractLane = true
  plan.runAllNodeTests = true
  plan.runCoreTests = true
  addExistingNativeTests(plan, NATIVE_CONTRACT_TESTS, inventory, reason)
}

function planForChanges(changedFiles, inventory = discoverInventory()) {
  const normalizedFiles = uniqueSorted(changedFiles.map(normalizeChangedFile).filter(Boolean))
  if (!normalizedFiles.length) throw new Error('no changed files were provided or discovered')

  const plan = createMutablePlan()
  const runtimeFiles = normalizedFiles.filter((file) => !isKnownNonRuntimeFile(file))

  for (const file of runtimeFiles) {
    if (file.startsWith('scripts/code-editor/')
        || file.startsWith('native/KaisolaMac/Kaisola/Resources/CodeEditor/')) {
      addExistingNodeTests(
        plan,
        ['tests/node/codeEditorBundle.test.cjs'],
        inventory,
        'confined code editor runtime changed',
      )
      addExistingNativeTests(plan, CODE_EDITOR_TESTS, inventory, 'confined code editor runtime changed')
      continue
    }

    if (file === 'scripts/native-test-select.cjs'
        || file === 'scripts/native-test-changed.sh'
        || file === 'scripts/native-build-timing.cjs'
        || file === 'scripts/native-fast.sh'
        || file === 'scripts/native-test-fast.sh') {
      addExistingNodeTests(plan, ['tests/node/nativeTestSelect.test.cjs'], inventory, 'fast-loop tooling changed')
      continue
    }

    if (file.startsWith('tests/node/') && file.endsWith('.test.cjs')) {
      addExistingNodeTests(plan, [file], inventory, `Node test changed: ${file}`)
      continue
    }

    const nativeTestMatch = file.match(/^native\/KaisolaMac\/KaisolaTests\/([^/]+Tests)\.swift$/u)
    if (nativeTestMatch) {
      addExistingNativeTests(plan, [nativeTestMatch[1]], inventory, `native test changed: ${nativeTestMatch[1]}`)
      continue
    }

    if (file.startsWith('native/KaisolaCore/')) {
      plan.runCoreTests = true
      plan.contractLane = true
      addExistingNativeTests(plan, NATIVE_CONTRACT_TESTS, inventory, 'shared Swift contract changed')
      plan.runAllNodeTests = true
      plan.reasons.add('shared Swift contract changed')
      continue
    }

    if (isBrokerOrSharedProtocolFile(file)) {
      plan.runAllNodeTests = true
      plan.runCoreTests = true
      plan.contractLane = true
      addExistingNativeTests(plan, NATIVE_CONTRACT_TESTS, inventory, 'broker/shared protocol changed')
      continue
    }

    if (isReleaseFile(file)) {
      plan.runAllNodeTests = true
      addExistingNodeTests(plan, RELEASE_NODE_TESTS, inventory, 'release contract changed')
      addExistingNativeTests(plan, [
        'BrokerHelperPackageTests', 'NativeUpdateConfigurationTests',
      ], inventory, 'release contract changed')
      continue
    }

    if (file.startsWith('native/KaisolaMac/Kaisola/') && file.endsWith('.swift')) {
      const exact = NATIVE_FILE_TESTS.get(file)
      if (exact) {
        addExistingNativeTests(plan, exact, inventory, `mapped native source changed: ${file}`)
        continue
      }

      const direct = matchingNativeTests(file, inventory)
      if (direct.length) {
        addExistingNativeTests(plan, direct, inventory, `matching native source changed: ${file}`)
        continue
      }

      const directoryPolicy = NATIVE_DIRECTORY_TESTS.find(([prefix]) => file.startsWith(prefix))
      if (directoryPolicy) {
        addExistingNativeTests(plan, directoryPolicy[1], inventory, `native feature area changed: ${directoryPolicy[0]}`)
        continue
      }

      applyBroadFallback(plan, inventory, `unmapped native source expanded coverage: ${file}`)
      continue
    }

    if (file.startsWith('mobile/KaisolaCompanion/')) {
      plan.runCoreTests = true
      plan.runAllNodeTests = true
      addExistingNativeTests(plan, [
        'CompanionConnectionSessionTests', 'CompanionProjectionBuilderTests',
        'CompanionTerminalControlTests',
      ], inventory, 'iPhone companion contract changed')
      continue
    }

    if (file.startsWith('scripts/') && file.endsWith('.cjs')) {
      const direct = nodeTestForScript(file, inventory)
      if (direct.length) {
        addExistingNodeTests(plan, direct, inventory, `matching Node tool changed: ${file}`)
      } else {
        applyBroadFallback(plan, inventory, `unmapped Node tool expanded coverage: ${file}`)
      }
      continue
    }

    if (file.startsWith('tests/fixtures/')) {
      applyBroadFallback(plan, inventory, `shared fixture expanded coverage: ${file}`)
      continue
    }

    if (file === 'native/KaisolaMac/project.yml'
        || file.endsWith('.xcodeproj/project.pbxproj')
        || file.endsWith('/Package.swift')
        || file.endsWith('/Package.resolved')) {
      applyBroadFallback(plan, inventory, `build graph expanded coverage: ${file}`)
      continue
    }

    applyBroadFallback(plan, inventory, `unmapped change expanded coverage: ${file}`)
  }

  if (!runtimeFiles.length) plan.reasons.add('known documentation-only change')

  return {
    schemaVersion: 1,
    changedFiles: normalizedFiles,
    native: {
      mode: plan.nativeSelectors.size ? (plan.contractLane ? 'contract' : 'focused') : 'none',
      selectors: uniqueSorted([...plan.nativeSelectors]),
    },
    node: {
      mode: plan.runAllNodeTests ? 'all' : (plan.nodeFiles.size ? 'focused' : 'none'),
      files: plan.runAllNodeTests ? [] : uniqueSorted([...plan.nodeFiles]),
    },
    swiftPackages: plan.runCoreTests ? ['native/KaisolaCore'] : [],
    fallback: plan.fallback,
    reasons: uniqueSorted([...plan.reasons]),
  }
}

function gitLines(args, root = repoRoot) {
  const result = spawnSync('/usr/bin/git', ['-C', root, ...args], { encoding: 'utf8' })
  if (result.error || result.status !== 0) {
    const detail = String(result.stderr || result.stdout || result.error?.message || '').trim()
    throw new Error(`git ${args.join(' ')} failed${detail ? `: ${detail}` : ''}`)
  }
  return String(result.stdout || '').split(/\r?\n/u).filter(Boolean)
}

function discoverChangedFiles({ base = null, staged = false, includeWorkingTree = false } = {}, root = repoRoot) {
  if (base && staged) throw new Error('--base and --staged are mutually exclusive')
  let files = []
  if (base) {
    files.push(...gitLines(['diff', '--name-only', '--diff-filter=ACMRD', `${base}...HEAD`], root))
  } else if (staged) {
    files.push(...gitLines(['diff', '--cached', '--name-only', '--diff-filter=ACMRD'], root))
  } else {
    includeWorkingTree = true
  }

  if (includeWorkingTree) {
    files.push(...gitLines(['diff', '--name-only', '--diff-filter=ACMRD', 'HEAD'], root))
    files.push(...gitLines(['ls-files', '--others', '--exclude-standard'], root))
  }
  return uniqueSorted(files.map(normalizeChangedFile).filter(Boolean))
}

function parseArguments(argv) {
  const options = {
    base: null,
    staged: false,
    includeWorkingTree: false,
    changedFiles: [],
    changedFilesFrom: null,
    format: 'text',
  }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const takeValue = () => {
      index += 1
      if (index >= argv.length) throw new Error(`${argument} requires a value`)
      return argv[index]
    }
    if (argument === '--base') options.base = takeValue()
    else if (argument === '--staged') options.staged = true
    else if (argument === '--include-working-tree') options.includeWorkingTree = true
    else if (argument === '--changed-file') options.changedFiles.push(takeValue())
    else if (argument === '--changed-files-from') options.changedFilesFrom = takeValue()
    else if (argument === '--format') options.format = takeValue()
    else if (argument === '--help' || argument === '-h') options.help = true
    else throw new Error(`unknown option: ${argument}`)
  }
  if (!['text', 'json'].includes(options.format)) throw new Error('--format must be text or json')
  return options
}

function usage() {
  return [
    'Usage: node scripts/native-test-select.cjs [change source] [--format text|json]',
    '',
    'Change sources (choose one):',
    '  --changed-file PATH       Explicit repository-relative path; repeatable',
    '  --changed-files-from FILE Read newline-delimited paths (use - for stdin)',
    '  --base REF                Committed REF...HEAD diff',
    '  --staged                  Staged diff',
    '  (default)                 Working-tree and untracked changes',
    '',
    '  --include-working-tree    Add working-tree changes to --base or --staged',
  ].join('\n')
}

function readChangedFileList(file) {
  const contents = file === '-' ? fs.readFileSync(0, 'utf8') : fs.readFileSync(file, 'utf8')
  return contents.split(/\r?\n/u).filter(Boolean)
}

function renderText(plan) {
  const lines = [
    `Changed files (${plan.changedFiles.length}):`,
    ...plan.changedFiles.map((file) => `  - ${file}`),
    `Native tests (${plan.native.mode}): ${plan.native.selectors.length ? plan.native.selectors.join(', ') : 'none'}`,
    `Node tests (${plan.node.mode}): ${plan.node.mode === 'focused' ? plan.node.files.join(', ') : plan.node.mode}`,
    `Swift packages: ${plan.swiftPackages.length ? plan.swiftPackages.join(', ') : 'none'}`,
    `Broad fallback: ${plan.fallback ? 'yes' : 'no'}`,
    'Selection reasons:',
    ...plan.reasons.map((reason) => `  - ${reason}`),
  ]
  return lines.join('\n')
}

function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv)
  if (options.help) {
    process.stdout.write(`${usage()}\n`)
    return
  }
  const explicitSource = options.changedFiles.length > 0 || options.changedFilesFrom
  if (explicitSource && (options.base || options.staged || options.includeWorkingTree)) {
    throw new Error('explicit changed files cannot be combined with Git diff options')
  }
  if (options.base && options.staged) throw new Error('--base and --staged are mutually exclusive')

  const changedFiles = explicitSource
    ? [...options.changedFiles, ...(options.changedFilesFrom ? readChangedFileList(options.changedFilesFrom) : [])]
    : discoverChangedFiles(options)
  const plan = planForChanges(changedFiles)
  process.stdout.write(options.format === 'json'
    ? `${JSON.stringify(plan, null, 2)}\n`
    : `${renderText(plan)}\n`)
}

if (require.main === module) {
  try {
    main()
  } catch (error) {
    process.stderr.write(`native-test-select: ${error.message}\n`)
    process.exitCode = 2
  }
}

module.exports = {
  NATIVE_CONTRACT_TESTS,
  discoverChangedFiles,
  discoverInventory,
  normalizeChangedFile,
  planForChanges,
  renderText,
}
