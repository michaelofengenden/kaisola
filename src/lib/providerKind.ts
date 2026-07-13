export type ProviderKind = 'openai' | 'claude' | 'generic'

export const providerKind = (provider?: string, name?: string): ProviderKind => {
  const key = `${provider ?? ''} ${name ?? ''}`.toLowerCase()
  if (/claude|anthropic/.test(key)) return 'claude'
  if (/codex|openai|chatgpt/.test(key)) return 'openai'
  return 'generic'
}
