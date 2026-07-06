const { app, BrowserWindow } = require('electron')
const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '..')
const svgPath = path.join(root, 'electron', 'assets', 'kaisola-icon.svg')
const pngPath = path.join(root, 'electron', 'assets', 'kaisola-icon.png')

app.disableHardwareAcceleration()

app.whenReady().then(async () => {
  const svg = fs.readFileSync(svgPath, 'utf8')
  const html = `<!doctype html>
    <meta charset="utf-8">
    <style>
      html, body {
        width: 1024px;
        height: 1024px;
        margin: 0;
        overflow: hidden;
        background: transparent;
      }
      img {
        display: block;
        width: 1024px;
        height: 1024px;
      }
    </style>
    <img alt="Kaisola" src="data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}">`

  const win = new BrowserWindow({
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    width: 1024,
    height: 1024,
  })

  await win.loadURL(`data:text/html;base64,${Buffer.from(html).toString('base64')}`)
  await new Promise((resolve) => setTimeout(resolve, 250))
  const image = await win.webContents.capturePage()
  fs.writeFileSync(pngPath, image.toPNG())
  win.destroy()
  app.quit()
}).catch((error) => {
  console.error(error)
  app.exit(1)
})
