// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

/// USB topology policies are executed by Rust; strings remain in the native device DTOs.
public enum DeviceTree {
    public static func parentLocationID(_ locationID: Int) -> Int? {
        let parent = aether_device_parent(Int64(locationID))
        return parent == 0 ? nil : Int(parent)
    }
    private static func query(_ device: DeviceInput, in all: [DeviceInput]) -> AetherDeviceTreeRow {
        let ids = all.map { Int64($0.locationID) }
        return ids.withUnsafeBufferPointer { aether_device_query($0.baseAddress, $0.count, Int64(device.locationID)) }
    }
    public static func hubDepth(of device: DeviceInput, in all: [DeviceInput]) -> Int {
        Int(query(device, in: all).depth)
    }
    public static func viaName(of device: DeviceInput, in all: [DeviceInput]) -> String? {
        let index = query(device, in: all).parent_index
        return index >= 0 && index < all.count ? all[index].productName : nil
    }
    static func plan(_ devices: [DeviceInput]) -> [AetherDeviceTreeRow] {
        let ids = devices.map { Int64($0.locationID) }
        var rows = [AetherDeviceTreeRow](repeating: .init(), count: ids.count)
        let count = ids.withUnsafeBufferPointer { input in
            rows.withUnsafeMutableBufferPointer { output in
                aether_device_plan(input.baseAddress, input.count, output.baseAddress, output.count)
            }
        }
        return count == rows.count ? rows : Array(rows.prefix(count))
    }
}
