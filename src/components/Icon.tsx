import { forwardRef } from 'react'
import * as Lucide from 'lucide-react'
import type { LucideProps } from 'lucide-react'

type IconName = keyof typeof Lucide

interface IconProps extends LucideProps {
  name: string
}

/**
 * Render a lucide icon by name (so domain metadata can carry icon strings).
 * Falls back to a neutral dot if the name is unknown.
 */
export const Icon = forwardRef<SVGSVGElement, IconProps>(function Icon({ name, ...props }, ref) {
  const Cmp = (Lucide as Record<string, unknown>)[name] as
    | React.ComponentType<LucideProps & { ref?: React.Ref<SVGSVGElement> }>
    | undefined
  const Fallback = Lucide.Circle
  const C = Cmp ?? Fallback
  return <C ref={ref} size={16} strokeWidth={1.75} {...props} />
})

export type { IconName }
