import QRCode from 'qrcode'

export interface PairingQrGraphic {
  path: string
  size: number
}

/** Build one compact SVG path from a standards-compliant QR matrix. The four
 * module quiet zone is part of the viewBox, so CSS cannot accidentally crop
 * the scanner's required whitespace. */
export function createPairingQrGraphic(payload: string): PairingQrGraphic {
  if (!payload) throw new Error('Pairing payload is empty.')
  const qr = QRCode.create(payload, { errorCorrectionLevel: 'L' })
  const quietZone = 4
  const matrixSize = qr.modules.size
  const commands: string[] = []

  // Merge horizontal runs into one rectangle apiece. This keeps even a dense
  // pairing payload crisp and substantially smaller than one SVG node per bit.
  for (let row = 0; row < matrixSize; row++) {
    let runStart = -1
    for (let column = 0; column <= matrixSize; column++) {
      const enabled = column < matrixSize && qr.modules.get(row, column) === 1
      if (enabled && runStart < 0) runStart = column
      if (!enabled && runStart >= 0) {
        const x = runStart + quietZone
        const y = row + quietZone
        commands.push(`M${x} ${y}h${column - runStart}v1H${x}z`)
        runStart = -1
      }
    }
  }

  return { path: commands.join(''), size: matrixSize + quietZone * 2 }
}
