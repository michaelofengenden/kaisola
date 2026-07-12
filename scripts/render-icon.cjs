const { app, BrowserWindow } = require('electron')
const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '..')
const svgPath = path.join(root, 'electron', 'assets', 'kaisola-icon.svg')
const pngPath = path.join(root, 'electron', 'assets', 'kaisola-icon.png')

app.disableHardwareAcceleration()

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    width: 1024,
    height: 1024,
  })

  await win.loadFile(svgPath)
  await new Promise((resolve) => setTimeout(resolve, 250))
  const image = await win.webContents.capturePage()
  fs.writeFileSync(pngPath, image.toPNG())
  win.destroy()
  app.quit()
}).catch((error) => {
  console.error(error)
  app.exit(1)
})
