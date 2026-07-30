import KaisolaCore
import SwiftUI
import VisionKit

/// A live QR scanner (VisionKit) that reports the decoded string. Falls back to
/// an "unavailable" state on devices/simulators without a usable camera, where
/// the paste-code path in PairingFlowView takes over.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        try? scanner.startScanning()
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            deliver(from: addedItems)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliver(from: [item])
        }

        private func deliver(from items: [RecognizedItem]) {
            guard !delivered else { return }
            for case let .barcode(barcode) in items {
                if let value = barcode.payloadStringValue, !value.isEmpty {
                    delivered = true
                    onCode(value)
                    return
                }
            }
        }
    }
}
