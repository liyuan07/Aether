import Foundation
import IOKit

// Reads live transport state from IOPortTransportState* services.
//
// These services provide real-time link data for each active transport
// on a port: actual data rate, generation, lane count, tunneling status.
// One service per transport type per port. Matched by ParentBuiltInPortNumber.
//
// Three transport types:
// - IOPortTransportStateUSB3: USB 3.x link (data rate, generation)
// - IOPortTransportStateDisplayPort: DP link (link rate, lane count, tunneled)
// - IOPortTransportStateCIO: Thunderbolt/USB4 CIO link (when TB device connected)

// MARK: - Raw data types

public struct RawUSB3TransportState: Sendable {
    public let portNumber: Int
    public let active: Bool
    public let dataRate: String          // "10 Gbps"
    public let generation: String        // "Gen 2"
    public let generationFamily: String  // "USB 3.x"
    public let tunneled: Bool
    // True when macOS Transport Restriction Mode has blocked data on this
    // link. The link can report a real signaling speed while Active is false
    // and data is shut off (e.g. an unauthorised device awaiting approval).
    // Without this flag a restricted port looks like a healthy idle port.
    public let transportRestricted: Bool
}

public struct RawDPTransportState: Sendable {
    public let portNumber: Int
    public let active: Bool
    public let linkRate: String          // "5.4 Gbps (HBR2)"
    public let laneCount: Int            // 2
    public let maxLaneCount: Int         // 4
    public let tunneled: Bool
    public let sinkCount: Int            // number of connected displays
    public let branchDevice: String      // MST hub / converter chip ID, e.g. "Dp1.2"
    public let dfpType: String           // downstream-facing port type, e.g. "HDMI"
}

public struct RawCIOTransportState: Sendable {
    public let portNumber: Int
    public let active: Bool
    public let dataRate: String
    public let tunneled: Bool
    // Which protocols are tunnelled over this TB/USB4 link right now
    // (e.g. ["USB3", "DisplayPort", "PCIe"]), and which the link could carry.
    public let tunnelProvisioned: [String]
    public let tunnelSupported: [String]
    // Identity of the connected Thunderbolt device (dock, hub) from its TB
    // controller, e.g. "TS3 Plus" / "CalDigit". Empty when not reported.
    public let deviceModel: String
    public let deviceVendor: String
}

// MARK: - Reader

public enum TransportStateReader {

    public static func readUSB3() -> [RawUSB3TransportState] {
        var results: [RawUSB3TransportState] = []

        withMatchingServices(className: "IOPortTransportStateUSB3") { service in
            guard let props = ioProperties(service) else { return }

            let data = RawUSB3TransportState(
                portNumber: ioInt(props["ParentBuiltInPortNumber"]),
                active: ioBool(props["Active"]),
                dataRate: ioString(props["DataRateDescription"]),
                generation: ioString(props["SuperSpeedSignalingDescription"]),
                generationFamily: ioString(props["GenerationDescription"]),
                tunneled: ioBool(props["Tunneled"]),
                transportRestricted: ioBool(props["TRM_TransportRestricted"])
            )
            results.append(data)
        }

        return results
    }

    public static func readDisplayPort() -> [RawDPTransportState] {
        var results: [RawDPTransportState] = []

        withMatchingServices(className: "IOPortTransportStateDisplayPort") { service in
            guard let props = ioProperties(service) else { return }

            let data = RawDPTransportState(
                portNumber: ioInt(props["ParentBuiltInPortNumber"]),
                active: ioBool(props["Active"]),
                linkRate: ioString(props["LinkRateDescription"]),
                laneCount: ioInt(props["LaneCount"]),
                maxLaneCount: ioInt(props["MaxLaneCount"]),
                tunneled: ioBool(props["Tunneled"]),
                sinkCount: ioInt(props["SinkCount"]),
                branchDevice: ioString(props["BranchDeviceID"]),
                dfpType: ioString(props["DFP Type Description"])
            )
            results.append(data)
        }

        return results
    }

    public static func readCIO() -> [RawCIOTransportState] {
        var results: [RawCIOTransportState] = []

        withMatchingServices(className: "IOPortTransportStateCIO") { service in
            guard let props = ioProperties(service) else { return }

            let data = RawCIOTransportState(
                portNumber: ioInt(props["ParentBuiltInPortNumber"]),
                active: ioBool(props["Active"]),
                dataRate: ioString(props["DataRateDescription"]),
                tunneled: ioBool(props["Tunneled"]),
                tunnelProvisioned: ioStringArray(props["TunneledTransportsProvisioned"]),
                tunnelSupported: ioStringArray(props["TunneledTransportsSupported"]),
                deviceModel: ioString(props["Device Model Name"]),
                deviceVendor: ioString(props["Device Vendor Name"])
            )
            results.append(data)
        }

        return results
    }
}
