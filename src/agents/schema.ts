import type { ModelTool } from '../lib/bridge'
import type {
  Proposal,
  ProposalChange,
  ChangeKind,
  EntityType,
  ProvenanceLink,
  TrajectoryStage,
} from '../domain/types'
import { uid, nowISO } from '../domain/ids'

/**
 * The structured-output contract. An agent forces a single `emit_proposal`
 * tool-call whose JSON schema mirrors the human-reviewable {@link Proposal}
 * type. The model fills only what it should author — title, summary, risks and
 * the per-change diff (kind / entityType / label / before / after / reason).
 * Everything machine-owned (id, agentId, stage, status, createdAt, evidence) is
 * filled by {@link toolInputToProposals} so the model can't forge provenance.
 *
 * The deserialized tool-call drops straight into `store.runAgent` →
 * `approveProposal()` — the single mutation path is untouched.
 */

const ENTITY_TYPES: EntityType[] = [
  'source', 'graph-node', 'graph-edge', 'question', 'hypothesis', 'experiment',
  'run', 'result', 'figure', 'section', 'inline-claim', 'review',
]
const CHANGE_KINDS: ChangeKind[] = ['create', 'update', 'delete']

export const EMIT_PROPOSAL_TOOL: ModelTool = {
  name: 'emit_proposal',
  description:
    'Emit one or more reviewable research proposals (research diffs) for the human to approve. ' +
    'Each proposal is a small, atomic, evidence-grounded change to the research trajectory. ' +
    'Be specific and conservative — a reviewer reads every word. Never invent results or citations.',
  input_schema: {
    type: 'object',
    additionalProperties: false,
    properties: {
      proposals: {
        type: 'array',
        description: 'One to three proposals. Prefer one tightly-scoped proposal over a sprawling one.',
        items: {
          type: 'object',
          additionalProperties: false,
          properties: {
            title: { type: 'string', description: 'Short imperative title, e.g. "Set novelty risk to 3/5".' },
            summary: { type: 'string', description: 'One or two sentences: what changes and why.' },
            risks: {
              type: 'array',
              items: { type: 'string' },
              description: 'What a skeptical reviewer would object to. Be honest.',
            },
            changes: {
              type: 'array',
              description: 'The atomic diffs this proposal applies on approval.',
              items: {
                type: 'object',
                additionalProperties: false,
                properties: {
                  kind: { type: 'string', enum: CHANGE_KINDS },
                  entityType: { type: 'string', enum: ENTITY_TYPES },
                  label: { type: 'string', description: 'Human label, e.g. "Add limitation".' },
                  before: { type: 'string', description: 'Current text (for updates/deletes).' },
                  after: { type: 'string', description: 'Proposed text (for creates/updates).' },
                  reason: { type: 'string', description: 'Why this change, grounded in evidence.' },
                },
                required: ['kind', 'entityType', 'label'],
              },
            },
          },
          required: ['title', 'summary', 'changes'],
        },
      },
    },
    required: ['proposals'],
  },
}

/**
 * The same contract as a strict OpenAI **structured output** (`response_format:
 * json_schema`, `strict: true`) — which *guarantees* schema-perfect output
 * instead of relying on tool-calling. Strict mode requires every property be
 * `required` and objects `additionalProperties:false`; genuinely-optional fields
 * are made nullable. `toolInputToProposals` treats null as absent.
 */
export const EMIT_PROPOSAL_JSON_SCHEMA = {
  name: 'emit_proposal',
  schema: {
    type: 'object',
    additionalProperties: false,
    properties: {
      proposals: {
        type: 'array',
        items: {
          type: 'object',
          additionalProperties: false,
          properties: {
            title: { type: 'string' },
            summary: { type: 'string' },
            risks: { type: ['array', 'null'], items: { type: 'string' } },
            changes: {
              type: 'array',
              items: {
                type: 'object',
                additionalProperties: false,
                properties: {
                  kind: { type: 'string', enum: CHANGE_KINDS },
                  entityType: { type: 'string', enum: ENTITY_TYPES },
                  label: { type: 'string' },
                  before: { type: ['string', 'null'] },
                  after: { type: ['string', 'null'] },
                  reason: { type: ['string', 'null'] },
                },
                required: ['kind', 'entityType', 'label', 'before', 'after', 'reason'],
              },
            },
          },
          required: ['title', 'summary', 'risks', 'changes'],
        },
      },
    },
    required: ['proposals'],
  },
} as const

interface RawChange {
  kind?: string
  entityType?: string
  label?: string | null
  before?: string | null
  after?: string | null
  reason?: string | null
}
interface RawProposal {
  title?: string
  summary?: string
  risks?: string[]
  changes?: RawChange[]
}

function coerceChange(c: RawChange): ProposalChange {
  const kind = (CHANGE_KINDS as string[]).includes(c.kind ?? '') ? (c.kind as ChangeKind) : 'update'
  const entityType = (ENTITY_TYPES as string[]).includes(c.entityType ?? '')
    ? (c.entityType as EntityType)
    : 'inline-claim'
  return {
    id: uid('ch'),
    kind,
    entityType,
    label: c.label?.trim() || 'Change',
    before: c.before ?? undefined,
    after: c.after ?? undefined,
    reason: c.reason ?? undefined,
  }
}

/**
 * Turn an `emit_proposal` tool-call input into validated {@link Proposal}s.
 * Tolerant of partial/garbled model output: anything missing is filled with a
 * safe default and obviously-empty proposals are dropped.
 */
export function toolInputToProposals(
  input: unknown,
  ctx: { agentId: Proposal['agentId']; stage: TrajectoryStage; evidence?: ProvenanceLink[] },
): Proposal[] {
  const raw = (input as { proposals?: RawProposal[] })?.proposals
  if (!Array.isArray(raw)) return []
  return raw
    .map((p): Proposal | null => {
      const changes = (p.changes ?? []).map(coerceChange)
      const title = p.title?.trim()
      if (!title && changes.length === 0) return null
      return {
        id: uid('prop'),
        agentId: ctx.agentId,
        stage: ctx.stage,
        title: title || 'Untitled proposal',
        summary: p.summary?.trim() || '',
        changes,
        evidence: ctx.evidence ?? [],
        risks: Array.isArray(p.risks) ? p.risks.filter((r) => typeof r === 'string') : undefined,
        status: 'pending',
        createdAt: nowISO(),
      }
    })
    .filter((p): p is Proposal => p !== null)
}
