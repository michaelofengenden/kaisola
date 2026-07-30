#!/usr/bin/env swift

import AppKit
import Foundation

private enum GateError: Error, CustomStringConvertible {
    case usage
    case unreadable(String)
    case transparent(String, Double)
    case flat(String, Double)

    var description: String {
        switch self {
        case .usage:
            return "pass one or more PNG paths"
        case let .unreadable(path):
            return "could not decode \(path)"
        case let .transparent(path, coverage):
            return "\(path) has only \(percentage(coverage)) visible sample coverage"
        case let .flat(path, range):
            return "\(path) has only \(String(format: "%.3f", range)) sampled luminance range"
        }
    }
}

private func percentage(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}

private func inspect(_ path: String) throws {
    let url = URL(fileURLWithPath: path, isDirectory: false)
    guard let data = try? Data(contentsOf: url),
          let bitmap = NSBitmapImageRep(data: data),
          bitmap.pixelsWide > 0,
          bitmap.pixelsHigh > 0 else {
        throw GateError.unreadable(path)
    }

    let columns = min(bitmap.pixelsWide, 64)
    let rows = min(bitmap.pixelsHigh, 64)
    var visible = 0
    var minimumLuminance = 1.0
    var maximumLuminance = 0.0
    let sampleCount = columns * rows

    for row in 0 ..< rows {
        let y = min(bitmap.pixelsHigh - 1, row * bitmap.pixelsHigh / rows)
        for column in 0 ..< columns {
            let x = min(bitmap.pixelsWide - 1, column * bitmap.pixelsWide / columns)
            guard let color = bitmap.colorAt(x: x, y: y)?
                .usingColorSpace(.deviceRGB) else { continue }
            if color.alphaComponent > 0.05 {
                visible += 1
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                minimumLuminance = min(minimumLuminance, luminance)
                maximumLuminance = max(maximumLuminance, luminance)
            }
        }
    }

    let coverage = sampleCount == 0 ? 0 : Double(visible) / Double(sampleCount)
    guard coverage >= 0.05 else {
        throw GateError.transparent(path, coverage)
    }
    let range = maximumLuminance - minimumLuminance
    guard range >= 0.04 else {
        throw GateError.flat(path, range)
    }
    print(
        "KAISOLA_NATIVE_VISUAL_CONTENT=PASS \(url.lastPathComponent) "
            + "visible=\(percentage(coverage)) luminanceRange=\(String(format: "%.3f", range))"
    )
}

do {
    let paths = Array(CommandLine.arguments.dropFirst())
    guard !paths.isEmpty else { throw GateError.usage }
    for path in paths.sorted() {
        try inspect(path)
    }
} catch {
    FileHandle.standardError.write(Data("KAISOLA_NATIVE_VISUAL_CONTENT=FAIL \(error)\n".utf8))
    exit(1)
}
