// Responsive visual probe for the static website. Renders the real site in
// Electron at desktop/mobile sizes, captures reviewable PNGs, and fails on the
// regressions that are easy to miss in source: horizontal overflow, missing
// product images, hidden CTAs, or a reintroduced CSS backdrop blur.
const { app, BrowserWindow, nativeTheme } = require('electron')
const path = require('node:path')
const os = require('node:os')
const fs = require('node:fs')

app.disableHardwareAcceleration()
app.setPath('userData', path.join(os.tmpdir(), 'kaisola-site-probe'))

const root = path.join(__dirname, '..')
const output = path.join(root, 'screenshots')
fs.mkdirSync(output, { recursive: true })
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function capture(win, name, width, height, theme, selector) {
  nativeTheme.themeSource = theme
  win.setSize(width, height)
  await win.loadFile(path.join(root, 'site', 'index.html'))
  await wait(420)
  if (selector) {
    await win.webContents.executeJavaScript(`(() => {
      document.documentElement.style.scrollBehavior = 'auto'
      const target = document.querySelector(${JSON.stringify(selector)})
      if (target) window.scrollTo(0, target.getBoundingClientRect().top + window.scrollY)
    })()`)
    await wait(180)
  }
  const image = await win.webContents.capturePage()
  const file = path.join(output, `${name}.png`)
  fs.writeFileSync(file, image.toPNG())
  return file
}

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    show: false,
    width: 1440,
    height: 1000,
    backgroundColor: '#ffffff',
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  })
  const screenshots = []
  try {
    screenshots.push(await capture(win, 'site-desktop-light', 1440, 1000, 'light'))
    const desktop = await win.webContents.executeJavaScript(`(() => {
      const nav = document.querySelector('.nav')
      const heroImage = document.querySelector('.product-frame img')
      const cta = document.querySelector('.hero .button')
      return {
        title: document.querySelector('h1')?.textContent?.trim(),
        noOverflow: document.documentElement.scrollWidth <= window.innerWidth,
        noBackdropBlur: getComputedStyle(nav).backdropFilter === 'none',
        noCurtain: !document.querySelector('canvas, [data-language-curtain]'),
        heroImageLoaded: !!heroImage && heroImage.complete && heroImage.naturalWidth > 0,
        ctaVisible: !!cta && cta.getBoundingClientRect().width > 0 && cta.getBoundingClientRect().bottom <= window.innerHeight,
      }
    })()`)
    screenshots.push(await capture(win, 'site-mesh-light', 1440, 1000, 'light', '#team'))
    screenshots.push(await capture(win, 'site-desktop-dark', 1440, 1000, 'dark'))
    screenshots.push(await capture(win, 'site-mobile-light', 390, 844, 'light'))
    const mobile = await win.webContents.executeJavaScript(`(() => ({
      noOverflow: document.documentElement.scrollWidth <= window.innerWidth,
      navFits: document.querySelector('.nav-inner')?.scrollWidth <= document.querySelector('.nav-inner')?.clientWidth,
      headlineFits: document.querySelector('h1')?.scrollWidth <= document.querySelector('h1')?.clientWidth,
      ctaVisible: !!document.querySelector('.hero .button'),
    }))()`)
    const result = { desktop, mobile, screenshots }
    console.log('SITE_UI=' + JSON.stringify(result))
    const ok = desktop.title === 'One place to run the work.'
      && Object.values(desktop).every(Boolean)
      && Object.values(mobile).every(Boolean)
    app.exit(ok ? 0 : 1)
  } catch (error) {
    console.error(error)
    app.exit(1)
  }
})
