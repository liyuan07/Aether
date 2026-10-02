import Foundation
import IOKit

// Reads connected display names from AppleATCDPAltModePort services.
//
// Each ATC (Apple Type-C) controller has an associated DP alt-mode port.
// When a display is connected (via direct DP alt-mode or tunneled through
// Thunderbolt), the "DisplayHints" dictionary is populated with the
// monitor's EDID product name, resolution, and color depth.
//
// The parent device tree node (e.g. "atc1-dpphy") has a "port-number"
// property that maps directly to the physical USB-C port.

public struct RawDisplayInfo: Sendable {
    public let portNumber: Int       // physical USB-C port
    public let productName: String   // EDID product name (e.g. "LEN G34w-10")
    public let maxWidth: Int         // native horizontal resolution
    public let maxHeight: Int        // native vertical resolution
}

public enum DisplayReader {
    public static func readDisplays() -> [RawDisplayInfo] {
        var results: [RawDisplayInfo] = []

        withMatchingServices(className: "AppleATCDPAltModePort") { service in
            guard let props = ioProperties(service) else { return }

            let hints = ioDictionary(props["DisplayHints"])
            let productName = ioString(hints["ProductName"])
            guard !productName.isEmpty else { return }

            // port-number on the parent atc-dpphy device tree node
            let portNumber = ioDataInt(ioParentProperty(service, key: "port-number")) ?? 0

            results.append(RawDisplayInfo(
                portNumber: portNumber,
                productName: productName,
                maxWidth: ioInt(hints["MaxW"]),
                maxHeight: ioInt(hints["MaxH"])
            ))
        }

        return results
    }
}
