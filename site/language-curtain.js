(() => {
  const canvas = document.querySelector('[data-language-curtain]')
  const host = canvas?.closest('.hero')
  const context = canvas?.getContext('2d')
  if (!canvas || !host || !context) return

  const lexicon = [
    ['English', ['r', 'e', 's', 'q']], ['French', ['é', 'ç', 'œ', 'à']],
    ['Portuguese', ['ã', 'ç', 'ê', 'õ']], ['Arabic', ['ب', 'ح', 'ث', 'ع', 'ل', 'م']],
    ['Chinese', ['研', '究', '知', '识']], ['Korean', ['연', '구', '지', '식']],
    ['Sanskrit', ['अ', 'नु', 'ज्ञा', 'नम्']], ['Spanish', ['ó', 'ñ', 'í', 's']],
    ['German', ['F', 'o', 'ß', 'W']], ['Japanese', ['探', '究', '知', '識']],
    ['Hindi', ['खो', 'ज', 'ज्ञा', 'न']], ['Greek', ['έ', 'ρ', 'γ', 'ν', 'ώ']],
    ['Hebrew', ['מ', 'ח', 'ק', 'ר', 'י', 'ד']], ['Swahili', ['u', 't', 'f', 'm']],
    ['Russian', ['и', 'с', 'л', 'з', 'н']], ['Turkish', ['ş', 'ı', 'ğ', 'ç']],
    ['Persian', ['پ', 'ژ', 'و', 'ه', 'ش']], ['Bengali', ['গ', 'বে', 'ষ', 'ণা', 'জ্ঞা']],
    ['Tamil', ['ஆ', 'ரா', 'ய்', 'அ', 'றி']], ['Amharic', ['ም', 'ር', 'እ', 'ው', 'ቀ']],
    ['Māori', ['ā', 'ū', 'wh', 'ng']], ['Vietnamese', ['ê', 'ứ', 'ệ', 'ứ']],
    ['Thai', ['วิ', 'จั', 'ย', 'รู้']], ['Urdu', ['ت', 'ح', 'ق', 'ی', 'ع']],
    ['Indonesian', ['p', 'e', 't', 'n']], ['Tagalog', ['p', 'n', 'l', 'k']],
    ['Georgian', ['კ', 'ვ', 'ლ', 'ც', 'ო']], ['Armenian', ['հ', 'ե', 'տ', 'գ', 'ի']],
    ['Yoruba', ['ì', 'wá', 'dí', 'mọ̀']], ['Irish', ['t', 'a', 'i', 'e']],
    ['Basque', ['i', 'k', 'e', 'z']], ['Welsh', ['y', 'm', 'ch', 'w']],
  ]
  const colors = ['#4c4b42', '#5d5a4c', '#6c6049', '#4d5b52', '#66554a']
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  const points = []
  let width = 0
  let height = 0
  let columns = 0
  let rows = 0
  let frame = 0
  let last = performance.now()
  let pointerX = Number.NaN
  let pointerY = Number.NaN
  const clamp = (value, low, high) => Math.max(low, Math.min(high, value))

  const rebuild = () => {
    const bounds = canvas.getBoundingClientRect()
    width = Math.max(1, bounds.width)
    height = Math.max(1, bounds.height)
    const dpr = Math.min(window.devicePixelRatio || 1, 1.5)
    canvas.width = Math.round(width * dpr)
    canvas.height = Math.round(height * dpr)
    context.setTransform(dpr, 0, 0, dpr, 0, 0)
    points.length = 0
    columns = clamp(Math.round(width / 42), 16, 36)
    const spacingX = width / Math.max(1, columns - 1)
    const spacingY = clamp(height / 31, 19, 25)
    rows = Math.ceil((height + spacingY * 2) / spacingY)

    for (let column = 0; column < columns; column += 1) {
      const restX = column * spacingX
      const stagger = (column % 4) * spacingY * .24
      for (let row = 0; row < rows; row += 1) {
        const language = lexicon[(column * 7 + row * 11) % lexicon.length]
        const restY = -spacingY + row * spacingY + stagger
        points.push({
          x: restX, y: restY, restX, restY, vx: 0, vy: 0, column, row,
          glyph: language[1][(row * 5 + column * 3) % language[1].length], language: language[0],
          color: colors[(column * 3 + row) % colors.length],
          fontSize: 9.4 + ((column + row * 2) % 4) * .7,
        })
      }
    }
  }

  const draw = () => {
    context.clearRect(0, 0, width, height)
    context.lineWidth = .55
    context.globalAlpha = dark ? .18 : .16
    for (let column = 0; column < columns; column += 1) {
      const first = points[column * rows]
      if (!first) continue
      context.beginPath()
      context.moveTo(first.restX, -8)
      for (let row = 0; row < rows; row += 1) {
        const point = points[column * rows + row]
        context.lineTo(point.x, point.y)
      }
      context.strokeStyle = dark ? '#b3ba8c' : '#575b45'
      context.stroke()
    }
    context.textAlign = 'center'
    context.textBaseline = 'middle'
    for (const point of points) {
      if (point.y < -18 || point.y > height + 18) continue
      context.globalAlpha = dark ? .62 : .51 + ((point.column + point.row) % 3) * .06
      context.fillStyle = dark ? '#b8c08c' : point.color
      context.font = `500 ${point.fontSize}px ui-serif, "Noto Serif", "Noto Sans", "Apple Symbols", Georgia, serif`
      context.fillText(point.glyph, point.x, point.y)
    }
    context.globalAlpha = 1
  }

  const tick = (now) => {
    const step = Math.min(1.8, (now - last) / 16.67)
    last = now
    const pointerActive = Number.isFinite(pointerX) && Number.isFinite(pointerY)
    const radius = clamp(Math.min(width, height) * .28, 130, 215)
    for (let column = 0; column < columns; column += 1) {
      for (let row = 0; row < rows; row += 1) {
        const index = column * rows + row
        const point = points[index]
        const above = row > 0 ? points[index - 1] : null
        const below = row + 1 < rows ? points[index + 1] : null
        const drift = Math.sin(now * .00028 + column * .71 + row * .04) * 1.8
        let forceX = (point.restX + drift - point.x) * (row === 0 ? .2 : .026)
        let forceY = (point.restY - point.y) * (row === 0 ? .22 : .055)
        if (above) {
          forceX += (above.x - point.x) * .062
          forceY += ((above.y + (point.restY - above.restY)) - point.y) * .028
        }
        if (below) {
          forceX += (below.x - point.x) * .062
          forceY += ((below.y - (below.restY - point.restY)) - point.y) * .028
        }
        if (pointerActive) {
          const dx = pointerX - point.x
          const dy = pointerY - point.y
          const distance = Math.max(1, Math.hypot(dx, dy))
          if (distance < radius) {
            const pressure = (1 - distance / radius) ** 2
            forceX += (dx / distance) * pressure * 2.7
            forceY += (dy / distance) * pressure * .82
          }
        }
        point.vx = (point.vx + forceX * step) * (.875 ** step)
        point.vy = (point.vy + forceY * step) * (.855 ** step)
      }
    }
    for (const point of points) {
      point.x += point.vx * step
      point.y += point.vy * step
    }
    draw()
    frame = requestAnimationFrame(tick)
  }

  const resize = new ResizeObserver(() => { rebuild(); draw() })
  resize.observe(canvas)
  host.addEventListener('pointermove', (event) => {
    const bounds = canvas.getBoundingClientRect()
    pointerX = event.clientX - bounds.left
    pointerY = event.clientY - bounds.top
  }, { passive: true })
  host.addEventListener('pointerleave', () => {
    pointerX = Number.NaN
    pointerY = Number.NaN
  }, { passive: true })
  document.addEventListener('visibilitychange', () => {
    cancelAnimationFrame(frame)
    if (!document.hidden && !reducedMotion) {
      last = performance.now()
      frame = requestAnimationFrame(tick)
    }
  })
  rebuild()
  draw()
  if (!reducedMotion) frame = requestAnimationFrame(tick)
})()
