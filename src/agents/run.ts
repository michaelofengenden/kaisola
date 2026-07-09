import type { Agent, AgentContext } from './types'
import type { Proposal } from '../domain/types'
import { bridge, type AcpUpdate } from '../lib/bridge'
import { extractJsonObject } from '../lib/extractJson'
import { EMIT_PROPOSAL_TOOL, EMIT_PROPOSAL_JSON_SCHEMA, toolInputToProposals } from './schema'

export interface RunResult {
  proposals: Proposal[]
  /** Whether the proposals came from a model/agent or the deterministic fallback. */
  source: 'model' | 'fallback'
  message?: string
}

/** Where the agent's reasoning runs. Cheap/subscription by default — never the expensive API. */
export interface RunOpts {
  provider?: 'openai' | 'anthropic' | 'agent' | 'codex'
  /** OpenAI-compatible base URL (local model). */
  baseUrl?: string
  /** Model name. */
  model?: string
  /** Use the keychain-stored OpenAI key (hosted OpenAI; key never reaches the renderer). */
  useStoredKey?: boolean
  /** For provider 'agent': which connected ACP terminal agent to route through. */
  agentKey?: string
  /** For provider 'codex': the workspace cwd for `codex exec`. */
  cwd?: string
  /** Owning project id for background ACP routing, even after tab switches. */
  scope?: string
}

const SCHEMA_HINT =
  'Reply with ONLY a JSON object (no prose, no markdown fences) of the form ' +
  '{"proposals":[{"title":string,"summary":string,"risks"?:string[],"changes":' +
  '[{"kind":"create"|"update"|"delete","entityType":string,"label":string,"before"?:string,"after"?:string,"reason"?:string}]}]}'

/** Route a domain agent through a connected ACP terminal agent (uses your CLI subscription). */
async function runViaAgent(agent: Agent, ctx: AgentContext, agentKey?: string, cwd?: string, scope?: string): Promise<Proposal[] | null> {
  if (!agentKey || !agent.prompt) return null
  const connectionKey = `${agentKey}::automation:${scope || 'default'}`
  const status = await bridge.acp.status([connectionKey], scope)
  if (!status.agents.find((a) => a.key === connectionKey)?.connected) {
    const connected = await bridge.acp.connect({ presetId: agentKey, clientKey: connectionKey, cwd, scope })
    if (!connected.ok) return null
  }
  const { system, user } = agent.prompt(ctx)
  let text = ''
  const leaseId = `automation:${agent.meta.id}`
  await bridge.acp.lease(connectionKey, leaseId, true, undefined, scope)
  try {
    const res = await bridge.acp.prompt(connectionKey, `${system}\n\n${user}\n\n${SCHEMA_HINT}`, (u: AcpUpdate) => {
      if (u.sessionUpdate === 'agent_message_chunk') text += u.content?.text ?? u.text ?? ''
    }, undefined, scope)
    if (!res.ok) return null
    const json = extractJsonObject(text)
    if (!json) return null
    return toolInputToProposals(json, { agentId: agent.meta.id, stage: agent.meta.stage, evidence: agent.evidence?.(ctx) })
  } finally {
    await bridge.acp.lease(connectionKey, leaseId, false, undefined, scope)
  }
}

/** Route through `codex exec` — runs on your ChatGPT/Codex subscription (no per-token API key). */
async function runViaCodex(agent: Agent, ctx: AgentContext, cwd?: string): Promise<Proposal[] | null> {
  if (!agent.prompt) return null
  const { system, user } = agent.prompt(ctx)
  const r = await bridge.codex.exec({ prompt: `${system}\n\n${user}\n\n${SCHEMA_HINT}`, cwd })
  if (!r.ok || !r.text) return null
  const json = extractJsonObject(r.text)
  if (!json) return null
  return toolInputToProposals(json, { agentId: agent.meta.id, stage: agent.meta.stage, evidence: agent.evidence?.(ctx) })
}

/**
 * Run an agent. Tries the configured reasoning provider (free local model by
 * default, an ACP terminal agent, or the paid API) via a forced `emit_proposal`
 * structured output; on any failure / empty output / unreachable model, falls
 * back to the agent's deterministic generator so the loop never dead-ends. The
 * single mutation path (`approveProposal`) is untouched either way.
 */
export async function runAgent(agent: Agent, ctx: AgentContext, opts: RunOpts = {}): Promise<RunResult> {
  if (agent.prompt) {
    try {
      if (opts.provider === 'agent') {
        const proposals = await runViaAgent(agent, ctx, opts.agentKey, opts.cwd, opts.scope)
        if (proposals && proposals.length) return { proposals, source: 'model' }
      } else if (opts.provider === 'codex') {
        const proposals = await runViaCodex(agent, ctx, opts.cwd)
        if (proposals && proposals.length) return { proposals, source: 'model' }
      } else {
        const { system, user } = agent.prompt(ctx)
        const res = await bridge.model.call({
          provider: opts.provider === 'anthropic' ? 'anthropic' : 'openai',
          baseUrl: opts.baseUrl,
          model: opts.model,
          useStoredKey: opts.useStoredKey,
          system,
          messages: [{ role: 'user', content: user }],
          tools: [EMIT_PROPOSAL_TOOL],
          toolChoice: { type: 'tool', name: 'emit_proposal' },
          // hosted OpenAI → guaranteed schema-perfect output via the SDK
          responseSchema: opts.useStoredKey ? (EMIT_PROPOSAL_JSON_SCHEMA as { name: string; schema: Record<string, unknown> }) : undefined,
          maxTokens: 2048,
        })
        if (res.ok && res.toolCalls && res.toolCalls.length) {
          const call = res.toolCalls.find((t) => t.name === 'emit_proposal') ?? res.toolCalls[0]
          const proposals = toolInputToProposals(call.input, {
            agentId: agent.meta.id,
            stage: agent.meta.stage,
            evidence: agent.evidence?.(ctx),
          })
          if (proposals.length) return { proposals, source: 'model' }
        }
      }
      // unreachable / no usable structured output → deterministic fallback
    } catch {
      /* network/parse error → deterministic fallback */
    }
  }
  const proposals = await agent.run(ctx)
  return { proposals, source: 'fallback' }
}
