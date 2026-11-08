import Foundation
#if canImport(IOKit)
import IOKit
#endif

/// Reads the hardware fingerprint from public system interfaces.
public enum HardwareProbe {
    public static func current() -> HardwareProfile {
        let brand = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        let (family, tier) = HardwareProfile.parseChip(brand)
        let performance = sysctlInt32("hw.perflevel0.physicalcpu") ?? sysctlInt32("hw.physicalcpu") ?? 0
        let efficiency = sysctlInt32("hw.perflevel1.physicalcpu") ?? 0
        let memoryBytes = sysctlInt64("hw.memsize") ?? 0
        let memoryGB = Int((Double(memoryBytes) / 1_073_741_824).rounded())
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = os.patchVersion > 0
            ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            : "\(os.majorVersion).\(os.minorVersion)"

        return HardwareProfile(
            chip: brand,
            chipFamily: family,
            chipTier: tier,
            performanceCores: Int(performance),
            efficiencyCores: Int(efficiency),
            gpuCores: gpuCoreCount(),
            memoryGB: memoryGB,
            macOS: macOS,
            rosetta: rosettaAvailable()
        )
    }

    /// Runs `/usr/bin/true` as x86_64. This succeeds only when Rosetta can translate it.
    public static func rosettaAvailable() -> Bool {
        #if arch(x86_64)
        return true
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
        #endif
    }

    /// Apple GPUs publish their core count on the AGXAccelerator IORegistry entry.
    static func gpuCoreCount() -> Int? {
        #if canImport(IOKit)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
            IOObjectRelease(service)
            if let number = value as? NSNumber {
                return number.intValue
            }
            service = IOIteratorNext(iterator)
        }
        return nil
        #else
        return nil
        #endif
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
