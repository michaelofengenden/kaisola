import { useEffect, useRef } from 'react'

interface LanguageGlyphs {
  language: string
  glyphs: readonly string[]
}

interface Bead {
  x: number
  y: number
  restX: number
  restY: number
  vx: number
  vy: number
  column: number
  row: number
  glyph: string
  language: string
  color: string
  fontSize: number
}

/** Graphemes from research and knowledge words, mixed within every strand. */
const LANGUAGES: readonly LanguageGlyphs[] = [
  { language: 'English', glyphs: ['r', 'e', 's', 'q'] },
  { language: 'French', glyphs: ['é', 'ç', 'œ', 'à'] },
  { language: 'Portuguese', glyphs: ['ã', 'ç', 'ê', 'õ'] },
  { language: 'Arabic', glyphs: ['ب', 'ح', 'ث', 'ع', 'ل', 'م'] },
  { language: 'Chinese', glyphs: ['研', '究', '知', '识'] },
  { language: 'Korean', glyphs: ['연', '구', '지', '식'] },
  { language: 'Sanskrit', glyphs: ['अ', 'नु', 'ज्ञा', 'नम्'] },
  { language: 'Spanish', glyphs: ['ó', 'ñ', 'í', 's'] },
  { language: 'German', glyphs: ['F', 'o', 'ß', 'W'] },
  { language: 'Japanese', glyphs: ['探', '究', '知', '識'] },
  { language: 'Hindi', glyphs: ['खो', 'ज', 'ज्ञा', 'न'] },
  { language: 'Greek', glyphs: ['έ', 'ρ', 'γ', 'ν', 'ώ'] },
  { language: 'Hebrew', glyphs: ['מ', 'ח', 'ק', 'ר', 'י', 'ד'] },
  { language: 'Swahili', glyphs: ['u', 't', 'f', 'm'] },
  { language: 'Russian', glyphs: ['и', 'с', 'л', 'з', 'н'] },
  { language: 'Turkish', glyphs: ['ş', 'ı', 'ğ', 'ç'] },
  { language: 'Persian', glyphs: ['پ', 'ژ', 'و', 'ه', 'ش'] },
  { language: 'Bengali', glyphs: ['গ', 'বে', 'ষ', 'ণা', 'জ্ঞা'] },
  { language: 'Tamil', glyphs: ['ஆ', 'ரா', 'ய்', 'அ', 'றி'] },
  { language: 'Amharic', glyphs: ['ም', 'ር', 'እ', 'ው', 'ቀ'] },
  { language: 'Māori', glyphs: ['ā', 'ū', 'wh', 'ng'] },
  { language: 'Vietnamese', glyphs: ['ê', 'ứ', 'ệ', 'ứ'] },
  { language: 'Thai', glyphs: ['วิ', 'จั', 'ย', 'รู้'] },
  { language: 'Urdu', glyphs: ['ت', 'ح', 'ق', 'ی', 'ع'] },
  { language: 'Indonesian', glyphs: ['p', 'e', 't', 'n'] },
  { language: 'Tagalog', glyphs: ['p', 'n', 'l', 'k'] },
  { language: 'Georgian', glyphs: ['კ', 'ვ', 'ლ', 'ც', 'ო'] },
  { language: 'Armenian', glyphs: ['հ', 'ե', 'տ', 'գ', 'ի'] },
  { language: 'Yoruba', glyphs: ['ì', 'wá', 'dí', 'mọ̀'] },
  { language: 'Irish', glyphs: ['t', 'a', 'i', 'e'] },
  { language: 'Basque', glyphs: ['i', 'k', 'e', 'z'] },
  { language: 'Welsh', glyphs: ['y', 'm', 'ch', 'w'] },
]

const COLORS = ['#4c4b42', '#5d5a4c', '#6c6049', '#4d5b52', '#66554a']

const clamp = (value: number, low: number, high: number) => Math.max(low, Math.min(high, value))

export function OnboardingBeads() {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    const host = canvas?.parentElement
    const context = canvas?.getContext('2d')
    if (!canvas || !host || !context) return

    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const beads: Bead[] = []
    let columns = 0
    let rows = 0
    let width = 0
    let height = 0
    let frame = 0
    let last = performance.now()
    let pointerX = Number.NaN
    let pointerY = Number.NaN

    const rebuild = () => {
      const bounds = host.getBoundingClientRect()
      width = Math.max(1, bounds.width)
      height = Math.max(1, bounds.height)
      const dpr = Math.min(window.devicePixelRatio || 1, 1.5)
      canvas.width = Math.round(width * dpr)
      canvas.height = Math.round(height * dpr)
      canvas.style.width = `${width}px`
      canvas.style.height = `${height}px`
      context.setTransform(dpr, 0, 0, dpr, 0, 0)

      beads.length = 0
      columns = clamp(Math.round(width / 25), 24, 64)
      const spacingX = width / Math.max(1, columns - 1)
      const spacingY = clamp(height / 68, 10.5, 15)
      rows = Math.ceil((height + spacingY * 2) / spacingY)

      for (let column = 0; column < columns; column += 1) {
        const restX = column * spacingX
        const stagger = (column % 4) * spacingY * 0.24
        for (let row = 0; row < rows; row += 1) {
          const lexicon = LANGUAGES[(column * 7 + row * 11) % LANGUAGES.length]
          const restY = -spacingY + row * spacingY + stagger
          beads.push({
            x: restX,
            y: restY,
            restX,
            restY,
            vx: 0,
            vy: 0,
            column,
            row,
            glyph: lexicon.glyphs[(row * 5 + column * 3) % lexicon.glyphs.length],
            language: lexicon.language,
            color: COLORS[(column * 3 + row) % COLORS.length],
            fontSize: 9.4 + ((column + row * 2) % 4) * 0.7,
          })
        }
      }
    }

    const draw = () => {
      context.clearRect(0, 0, width, height)
      context.lineWidth = 0.55
      context.globalAlpha = 0.19
      for (let column = 0; column < columns; column += 1) {
        const first = beads[column * rows]
        if (!first) continue
        context.beginPath()
        context.moveTo(first.restX, -8)
        for (let row = 0; row < rows; row += 1) {
          const bead = beads[column * rows + row]
          context.lineTo(bead.x, bead.y)
        }
        context.strokeStyle = '#575b45'
        context.stroke()
      }

      context.textAlign = 'center'
      context.textBaseline = 'middle'
      for (const bead of beads) {
        if (bead.y < -18 || bead.y > height + 18) continue
        context.globalAlpha = bead.row === 0 ? 0.8 : 0.54 + ((bead.column + bead.row) % 3) * 0.07
        context.fillStyle = bead.color
        context.font = `500 ${bead.fontSize}px ui-serif, "Noto Serif", "Noto Sans", "Apple Symbols", Georgia, serif`
        context.fillText(bead.glyph, bead.x, bead.y)
      }
      context.globalAlpha = 1
    }

    const tick = (now: number) => {
      const step = Math.min(1.8, (now - last) / 16.67)
      last = now
      const pointerActive = Number.isFinite(pointerX) && Number.isFinite(pointerY)
      const influenceRadius = clamp(Math.min(width, height) * 0.25, 130, 220)

      for (let column = 0; column < columns; column += 1) {
        for (let row = 0; row < rows; row += 1) {
          const index = column * rows + row
          const bead = beads[index]
          const above = row > 0 ? beads[index - 1] : null
          const below = row + 1 < rows ? beads[index + 1] : null
          const drift = Math.sin(now * 0.00024 + column * 0.71 + row * 0.04) * 1.55
          const anchorStrength = row === 0 ? 0.18 : 0.022
          let forceX = (bead.restX + drift - bead.x) * anchorStrength
          let forceY = (bead.restY - bead.y) * (row === 0 ? 0.22 : 0.055)

          if (above) {
            forceX += (above.x - bead.x) * 0.062
            forceY += ((above.y + (bead.restY - above.restY)) - bead.y) * 0.028
          }
          if (below) {
            forceX += (below.x - bead.x) * 0.062
            forceY += ((below.y - (below.restY - bead.restY)) - bead.y) * 0.028
          }

          if (pointerActive) {
            const dx = pointerX - bead.x
            const dy = pointerY - bead.y
            const distance = Math.max(1, Math.hypot(dx, dy))
            if (distance < influenceRadius) {
              const pressure = (1 - distance / influenceRadius) ** 2
              // Repel from the pointer. The previous sign pulled the strands
              // toward it, which made the curtain bunch under the cursor.
              forceX -= (dx / distance) * pressure * 2.45
              forceY -= (dy / distance) * pressure * 0.72
            }
          }

          bead.vx = (bead.vx + forceX * step) * (0.895 ** step)
          bead.vy = (bead.vy + forceY * step) * (0.885 ** step)
        }
      }

      for (const bead of beads) {
        bead.x += bead.vx * step
        bead.y += bead.vy * step
      }
      draw()
      frame = window.requestAnimationFrame(tick)
    }

    const onPointerMove = (event: PointerEvent) => {
      const bounds = host.getBoundingClientRect()
      pointerX = event.clientX - bounds.left
      pointerY = event.clientY - bounds.top
    }
    const clearPointer = () => {
      pointerX = Number.NaN
      pointerY = Number.NaN
    }
    const onVisibility = () => {
      window.cancelAnimationFrame(frame)
      if (!document.hidden && !reducedMotion) {
        last = performance.now()
        frame = window.requestAnimationFrame(tick)
      }
    }

    const resize = new ResizeObserver(() => { rebuild(); draw() })
    resize.observe(host)
    rebuild()
    draw()
    host.addEventListener('pointermove', onPointerMove, { passive: true })
    host.addEventListener('pointerleave', clearPointer, { passive: true })
    document.addEventListener('visibilitychange', onVisibility)
    if (!reducedMotion) frame = window.requestAnimationFrame(tick)
    return () => {
      resize.disconnect()
      window.cancelAnimationFrame(frame)
      host.removeEventListener('pointermove', onPointerMove)
      host.removeEventListener('pointerleave', clearPointer)
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [])

  return <canvas ref={canvasRef} className="onboarding-beads" aria-hidden="true" />
}
