// Pure geometry probe for window-local wallpaper average sampling:
//   node electron/glasscropprobe.cjs
const assert = require('node:assert/strict')
const { __test } = require('./ipc/glassHandler.cjs')

const cases = [
  {
    name: '4:3 wallpaper fills 16:9 display without stretching',
    image: { width: 4000, height: 3000 },
    display: { width: 1920, height: 1080 },
    expected: { x: 0, y: 375, width: 4000, height: 2250 },
  },
  {
    name: 'wide wallpaper fills square display from its center',
    image: { width: 2000, height: 1000 },
    display: { width: 1000, height: 1000 },
    expected: { x: 500, y: 0, width: 1000, height: 1000 },
  },
  {
    name: 'matching aspect keeps every source pixel',
    image: { width: 2560, height: 1440 },
    display: { width: 1280, height: 720 },
    expected: { x: 0, y: 0, width: 2560, height: 1440 },
  },
]

try {
  for (const c of cases) assert.deepEqual(__test.aspectFillRect(c.image, c.display), c.expected, c.name)
  console.log(`GLASS_CROP=PASS cases=${cases.length}`)
} catch (error) {
  console.error('GLASS_CROP=FAIL', error)
  process.exitCode = 1
}
