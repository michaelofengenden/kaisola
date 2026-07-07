import { useEffect, useMemo } from 'react'
import {
  ReactFlow,
  Background,
  Controls,
  Handle,
  Position,
  MarkerType,
  useNodesState,
  useEdgesState,
  type Node,
  type Edge,
  type NodeProps,
} from '@xyflow/react'
import { useKaisola } from '../store/store'
import { ViewHeader } from '../components/ViewHeader'
import { Icon } from '../components/Icon'
import { TrustBadge } from '../components/TrustBadge'
import { ProvenanceChip } from '../components/Provenance'
import { EmptyState } from '../components/EmptyState'
import { lintProvenanced, lintSeverity } from '../lib/lint'
import type { GraphNode, GraphNodeType, GraphRelation } from '../domain/types'

/** Each node type gets a CSS-var hue so the legend and the node borders agree. */
const TYPE_HUE: Record<GraphNodeType, string> = {
  claim: 'var(--accent)',
  method: 'var(--agent-planning)',
  dataset: 'var(--info)',
  metric: 'var(--info)',
  result: 'var(--success)',
  limitation: 'var(--warn)',
  assumption: 'var(--text-2)',
  question: 'var(--agent-novelty)',
  contradiction: 'var(--danger)',
}

/** Edge stroke by relation — contradictions read as danger, support as accent. */
const RELATION_STROKE: Record<GraphRelation, string> = {
  supports: 'var(--accent)',
  contradicts: 'var(--danger)',
  uses: 'var(--text-2)',
  measures: 'var(--info)',
  motivates: 'var(--agent-novelty)',
  extends: 'var(--success)',
  addresses: 'var(--agent-planning)',
}

type GraphNodeData = { node: GraphNode }
type FlowNode = Node<GraphNodeData, 'graphNode'>

/** Custom react-flow node: type tag, label, then trust + evidence in the foot. */
function GraphFlowNode({ data }: NodeProps<FlowNode>) {
  const n = data.node
  const issues = lintProvenanced(n)
  const sev = lintSeverity(issues)
  return (
    <div className={`gnode gnode-${n.type}${sev ? ` gnode-lint-${sev}` : ''}`} title={issues.map((i) => i.message).join('\n') || undefined}>
      <Handle type="target" position={Position.Left} />
      <div className="gnode-type">{n.type.toUpperCase()}</div>
      <div className="gnode-label">{n.label}</div>
      <div className="gnode-foot">
        <TrustBadge trust={n.trust} compact />
        {sev && (
          <span className={`gnode-lint-flag lint-${sev}`}>
            <Icon name={sev === 'unsupported' ? 'AlertTriangle' : 'BadgeAlert'} size={10} />
          </span>
        )}
        <ProvenanceChip links={n.provenance} title={n.label} />
      </div>
      <Handle type="source" position={Position.Right} />
    </div>
  )
}

const nodeTypes = { graphNode: GraphFlowNode }

export function ClaimGraphView() {
  const claimGraph = useKaisola((s) => s.project.claimGraph)
  const verifyCitations = useKaisola((s) => s.verifyCitations)
  const lintCount = claimGraph.nodes.reduce((a, n) => a + lintProvenanced(n).length, 0)

  const initialNodes = useMemo<FlowNode[]>(
    () =>
      claimGraph.nodes.map((n) => ({
        id: n.id,
        type: 'graphNode',
        position: n.position ?? { x: 0, y: 0 },
        data: { node: n },
      })),
    [claimGraph.nodes],
  )

  const initialEdges = useMemo<Edge[]>(
    () =>
      claimGraph.edges.map((e) => ({
        id: e.id,
        source: e.source,
        target: e.target,
        label: e.relation,
        animated: e.relation === 'contradicts',
        style: {
          stroke: RELATION_STROKE[e.relation],
          strokeWidth: e.weight != null ? 1 + e.weight * 2 : 1.5,
        },
        labelStyle: { fontSize: 10, fill: 'var(--text-2)' },
        labelBgStyle: { fill: 'var(--bg-2)', fillOpacity: 0.9 },
        markerEnd: { type: MarkerType.ArrowClosed, color: RELATION_STROKE[e.relation] },
      })),
    [claimGraph.edges],
  )

  const [nodes, setNodes, onNodesChange] = useNodesState<FlowNode>(initialNodes)
  const [edges, setEdges, onEdgesChange] = useEdgesState(initialEdges)

  /** initialNodes/initialEdges re-memoize on store edits — push them into the
   *  canvas so verify/apply/ingest changes land. Merge by id so a local drag
   *  position + selection survives a store write (e.g. a no-op Verify that
   *  rebuilds the nodes array); only genuinely new nodes take their store position. */
  useEffect(() => {
    setNodes((cur) => {
      const prev = new Map(cur.map((n) => [n.id, n]))
      return initialNodes.map((n) => {
        const p = prev.get(n.id)
        return p ? { ...n, position: p.position, selected: p.selected } : n
      })
    })
  }, [initialNodes, setNodes])
  useEffect(() => { setEdges(initialEdges) }, [initialEdges, setEdges])

  /** Only legend the types that actually appear, in a stable canonical order. */
  const presentTypes = useMemo<GraphNodeType[]>(() => {
    const order = Object.keys(TYPE_HUE) as GraphNodeType[]
    const seen = new Set(claimGraph.nodes.map((n) => n.type))
    return order.filter((t) => seen.has(t))
  }, [claimGraph.nodes])

  if (claimGraph.nodes.length === 0) {
    return (
      <div className="view">
        <ViewHeader icon="Network" title="Claim Graph" sub="Claims, methods & contradictions" />
        <EmptyState
          icon="Network"
          title="No claims extracted yet"
          hint="Add papers to the corpus, then run the literature agent to extract claims, methods, and contradictions."
        />
      </div>
    )
  }

  return (
    <div className="view">
      <ViewHeader
        icon="Network"
        title="Claim Graph"
        sub="Claims, methods, limitations & contradictions extracted from the corpus"
      >
        {lintCount > 0 && (
          <button className="btn btn-sm" onClick={() => { void verifyCitations() }} title="Unsupported or cited-but-unverified claims — run Verify citations">
            <Icon name="BadgeAlert" size={13} style={{ color: 'var(--warn)' }} /> {lintCount} issue{lintCount > 1 ? 's' : ''}
          </button>
        )}
        <button className="btn btn-sm">
          <Icon name="Sparkles" size={13} /> Extract more
        </button>
      </ViewHeader>

      <div className="graph-wrap" style={{ flex: 1, minHeight: 0 }}>
        <ReactFlow
          nodes={nodes}
          edges={edges}
          onNodesChange={onNodesChange}
          onEdgesChange={onEdgesChange}
          nodeTypes={nodeTypes}
          fitView
          proOptions={{ hideAttribution: true }}
          style={{ width: '100%', height: '100%' }}
        >
          <Background />
          <Controls />
        </ReactFlow>

        <div className="graph-legend">
          {presentTypes.map((t) => (
            <div key={t} className="legend-row">
              <span className="legend-swatch" style={{ background: TYPE_HUE[t] }} />
              {t}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
