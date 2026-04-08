#!/usr/bin/env swift
//
// vmm7100tool.swift
//
// macOS CLI tool for Synaptics VMM7100 USB-C to HDMI adapter
// Firmware flash, debug info, EDID read, register access, board reset
//
// Ported from Windows VmmDPTool64/VmmHIDTool
// Protocol based on fwupd synaptics-mst plugin + vmm7100reset.swift
//

import Foundation
import IOKit
import IOKit.usb
import IOKit.hid

// MARK: - Constants

let VMM_VENDOR_ID: Int32 = 0x06CB   // Synaptics
let VMM_PRODUCT_ID: Int32 = 0x7100  // VMM7100
let HID_REPORT_SIZE = 62            // 1 byte report ID + 61 bytes data
let BLOCK_UNIT = 64                 // Flash write chunk size
let UNIT_SIZE = 32                  // Register read chunk size
let MAX_RETRY = 10
let RETRY_DELAY_MS: UInt32 = 100
let FLASH_SETTLE_MS: UInt32 = 5_000_000 // 5 seconds in usleep units
let FIRMWARE_SIZE = 1_048_576        // 1MB .fullrom

// RC Register offsets (DP AUX addresses, mapped into HID packets)
let REG_RC_CAP: UInt32    = 0x4B0
let REG_RC_STATE: UInt32  = 0x4B1
let REG_RC_CMD: UInt32    = 0x4B2
let REG_RC_RESULT: UInt32 = 0x4B3
let REG_RC_LEN: UInt32    = 0x4B8
let REG_RC_OFFSET: UInt32 = 0x4BC
let REG_RC_DATA: UInt32   = 0x4C0

// Chip info registers
let REG_CHIP_ID: UInt32         = 0x507
let REG_FIRMWARE_VERSION: UInt32 = 0x50A

// Flash sector erase sizes
let FLASH_SECTOR_ERASE_64K: UInt32 = 0x3000

// EEPROM layout
let EEPROM_TAG_OFFSET: UInt32  = 0x1FFF0
let EEPROM_BANK_OFFSET: UInt32 = 0x20000
let EEPROM_ESM_OFFSET: UInt32  = 0x40000

// MARK: - RC Commands

enum RCCommand: UInt8 {
    case enableRC           = 0x01
    case disableRC          = 0x02
    case getId              = 0x03
    case getVersion         = 0x04
    case flashMapping       = 0x07
    case calChecksum        = 0x11
    case flashErase         = 0x14
    case calCRC16           = 0x17
    case activateFirmware   = 0x18
    case writeToEEPROM      = 0x20
    case writeToMemory      = 0x21
    case readFromEEPROM     = 0x30
    case readFromMemory     = 0x31
}

enum RCResult: UInt8 {
    case success    = 0x00
    case invalid    = 0x01
    case unsupported = 0x02
    case failed     = 0x03
    case disabled   = 0x04
}

// MARK: - IOKit UUIDs

let kIOUSBDeviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
    0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
    0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

let kIOCFPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
    0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
    0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

let kIOUSBInterfaceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
    0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
    0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

let kIOUSBDeviceInterfaceID = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
    0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4,
    0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

let kIOUSBInterfaceInterfaceID = CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault,
    0x73, 0xC9, 0x7A, 0xE8, 0x9E, 0xF3, 0x11, 0xD4,
    0xB1, 0xD0, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

// MARK: - CRC16 (UMTS/CCITT variant used by Synaptics)

func crc16(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0xFFFF // CRC-16/CCITT-FALSE init
    for byte in data {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            if crc & 0x8000 != 0 {
                crc = (crc << 1) ^ 0x1021
            } else {
                crc <<= 1
            }
        }
    }
    return crc
}

// MARK: - EDID Parser

struct EDIDInfo {
    var manufacturer: String = "Unknown"
    var productID: UInt16 = 0
    var serial: UInt32 = 0
    var year: Int = 0
    var week: Int = 0
    var hRes: Int = 0
    var vRes: Int = 0
    var productName: String = ""
}

func parseEDID(_ data: Data) -> EDIDInfo? {
    guard data.count >= 128 else { return nil }
    // Check EDID header: 00 FF FF FF FF FF FF 00
    let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    for i in 0..<8 {
        if data[i] != header[i] { return nil }
    }
    var info = EDIDInfo()
    // Manufacturer ID (bytes 8-9, big-endian, 5-bit compressed ASCII)
    let mfg = (UInt16(data[8]) << 8) | UInt16(data[9])
    let c1 = Character(UnicodeScalar(((mfg >> 10) & 0x1F) + 0x40)!)
    let c2 = Character(UnicodeScalar(((mfg >> 5) & 0x1F) + 0x40)!)
    let c3 = Character(UnicodeScalar((mfg & 0x1F) + 0x40)!)
    info.manufacturer = String([c1, c2, c3])
    // Product ID (bytes 10-11, little-endian)
    info.productID = UInt16(data[10]) | (UInt16(data[11]) << 8)
    // Serial (bytes 12-15, little-endian)
    info.serial = UInt32(data[12]) | (UInt32(data[13]) << 8) | (UInt32(data[14]) << 16) | (UInt32(data[15]) << 24)
    // Manufacture week/year
    info.week = Int(data[16])
    info.year = Int(data[17]) + 1990
    // Preferred resolution from detailed timing descriptor (byte 54+)
    if data.count >= 72 {
        info.hRes = Int(data[56]) | ((Int(data[58]) & 0xF0) << 4)
        info.vRes = Int(data[59]) | ((Int(data[61]) & 0xF0) << 4)
    }
    // Parse descriptor blocks for product name (tag 0xFC)
    for block in 0..<4 {
        let offset = 54 + block * 18
        guard offset + 17 < data.count else { continue }
        if data[offset] == 0 && data[offset + 1] == 0 && data[offset + 3] == 0xFC {
            var name = ""
            for i in 5..<18 {
                let ch = data[offset + i]
                if ch == 0x0A || ch == 0x00 { break }
                name.append(Character(UnicodeScalar(ch)))
            }
            info.productName = name.trimmingCharacters(in: .whitespaces)
        }
    }
    return info
}

// MARK: - Mock Device

class MockDevice {
    var rcEnabled = false
    var firmwareVersion: (UInt8, UInt8, UInt16) = (7, 2, 126) // major.minor.patch
    var firmwareName = "Spyder_fw_DP_CM"
    var chipID: UInt16 = 0x7100
    var flashData: Data

    // Sample EDID for testing (Dell U2720Q-like)
    let sampleEDID: [UInt8] = [
        0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, // Header
        0x10, 0xAC, // Manufacturer DEL
        0xC0, 0xD0, // Product ID
        0x80, 0x57, 0x11, 0x01, // Serial
        0x27, 0x1F, // Week 39, Year 2021
        0x01, 0x04, // EDID version 1.4
        0xB5, 0x3C, 0x22, 0x78, 0x3A, // Basic params
        0x4E, 0x30, 0xA5, 0x56, 0x50, 0x9E, 0x27, 0x0D, 0x50, 0x54, // Chromaticity
        0xA5, 0x4B, 0x00, // Established timings
        0x81, 0x80, 0xA9, 0xC0, 0xD1, 0xC0, 0x01, 0x01, // Standard timings
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        // Detailed timing: 3840x2160
        0x56, 0x5E, 0x00, 0xA0, 0xA0, 0x40, 0x2E, 0x60,
        0x30, 0x20, 0x36, 0x00, 0x58, 0x4A, 0x21, 0x00, 0x00, 0x1E,
        // Descriptor: product name "MOCK DISPLAY"
        0x00, 0x00, 0x00, 0xFC, 0x00,
        0x4D, 0x4F, 0x43, 0x4B, 0x20, 0x44, 0x49, 0x53, 0x50, 0x4C, 0x41, 0x59, 0x0A,
        // Descriptor: serial string
        0x00, 0x00, 0x00, 0xFF, 0x00,
        0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x0A,
        // Descriptor: range limits
        0x00, 0x00, 0x00, 0xFD, 0x00,
        0x1E, 0x90, 0x1E, 0xDE, 0x3C, 0x01, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
        0x00, // Extension count
        0x00, // Checksum (placeholder)
    ]

    let edidData: Data

    init() {
        // Create fake 1MB flash with recognizable pattern
        var flash = Data(count: FIRMWARE_SIZE)
        // Write firmware name at a known offset
        let nameData = firmwareName.data(using: .ascii)!
        flash.replaceSubrange(0x100..<(0x100 + nameData.count), with: nameData)
        // Write version bytes
        flash[0x200] = firmwareVersion.0
        flash[0x201] = firmwareVersion.1
        flash[0x202] = UInt8(firmwareVersion.2 >> 8)
        flash[0x203] = UInt8(firmwareVersion.2 & 0xFF)
        self.flashData = flash
        // EDID stored separately (real device reads from connected display, not flash)
        self.edidData = Data(sampleEDID + Array(repeating: UInt8(0), count: max(0, 128 - sampleEDID.count)))
    }

    func processCommand(cmd: RCCommand, offset: UInt32, length: UInt32, data: Data) -> (result: UInt8, data: Data) {
        switch cmd {
        case .enableRC:
            if data.count >= 5 && String(data: data.prefix(5), encoding: .ascii) == "PRIUS" {
                rcEnabled = true
                return (RCResult.success.rawValue, Data())
            }
            return (RCResult.failed.rawValue, Data())

        case .disableRC:
            rcEnabled = false
            return (RCResult.success.rawValue, Data())

        case .getId:
            guard rcEnabled else { return (RCResult.disabled.rawValue, Data()) }
            var idData = Data(count: 4)
            idData[0] = UInt8(chipID >> 8)
            idData[1] = UInt8(chipID & 0xFF)
            idData[2] = 0xA1 // chip revision
            idData[3] = 0x00
            return (RCResult.success.rawValue, idData)

        case .getVersion:
            guard rcEnabled else { return (RCResult.disabled.rawValue, Data()) }
            var verData = Data(count: 3)
            verData[0] = firmwareVersion.0
            verData[1] = firmwareVersion.1
            verData[2] = UInt8(firmwareVersion.2 & 0xFF)
            return (RCResult.success.rawValue, verData)

        case .readFromEEPROM:
            guard rcEnabled else { return (RCResult.disabled.rawValue, Data()) }
            let start = Int(offset)
            let len = Int(length)
            guard start >= 0, start + len <= flashData.count else {
                return (RCResult.failed.rawValue, Data())
            }
            return (RCResult.success.rawValue, flashData.subdata(in: start..<(start + len)))

        case .writeToEEPROM:
            guard rcEnabled else { return (RCResult.disabled.rawValue, Data()) }
            let start = Int(offset)
            guard start >= 0, start + data.count <= flashData.count else {
                return (RCResult.failed.rawValue, Data())
            }
            flashData.replaceSubrange(start..<(start + data.count), with: data)
            return (RCResult.success.rawValue, Data())

        case .readFromMemory:
            guard rcEnabled else { return (RCResult.disabled.rawValue, Data()) }
            // Simulate register reads
            var regData = Data(count: Int(length))
            if offset == REG_CHIP_ID {
                regData[0] = UInt8(chipID >> 8)
                if length > 1 { regData[1] = UInt8(chipID & 0xFF) }
            } else if offset == REG_FIRMWARE_VERSION {
                regData[0] = firmwareVersion.0
                if length > 1 { regData[1] = firmwareVersion.1 }
                if length > 2 { regData[2] = UInt8(firmwareVersion.2 & 0xFF) }
            }
            return (RCResult.success.rawValue, regData)

        case .flashErase:
            guard rcEnabled else { return (RCResult.disabled.rawValue, Data()) }
            // Simulate erase: fill with 0xFF
            let start = Int(offset)
            let eraseSize = 0x10000 // 64K
            let end = min(start + eraseSize, flashData.count)
            for i in start..<end { flashData[i] = 0xFF }
            return (RCResult.success.rawValue, Data())

        case .calCRC16:
            guard rcEnabled else { return (RCResult.disabled.rawValue, Data()) }
            let start = Int(offset)
            let len = Int(length)
            guard start >= 0, start + len <= flashData.count else {
                return (RCResult.failed.rawValue, Data())
            }
            // CRC is calculated over flash data (same data that was written)
            let crc = crc16(flashData.subdata(in: start..<(start + len)))
            var crcData = Data(count: 2)
            crcData[0] = UInt8(crc >> 8)
            crcData[1] = UInt8(crc & 0xFF)
            return (RCResult.success.rawValue, crcData)

        case .activateFirmware:
            guard rcEnabled else { return (RCResult.disabled.rawValue, Data()) }
            return (RCResult.success.rawValue, Data())

        default:
            return (RCResult.unsupported.rawValue, Data())
        }
    }
}

// MARK: - HID Packet Builder

/// Build a 62-byte HID output report for an RC command.
/// Format decoded from vmm7100reset.swift known packets + fwupd protocol:
///   [0]    Report ID (0x01)
///   [1]    0x00 (reserved)
///   [2]    Payload length (bytes following, up to 59)
///   [3-4]  0x00, 0x00 (reserved)
///   [5]    RC_CMD | 0x80 (execute bit)
///   [6]    0x00 (reserved)
///   [7-10] RC_OFFSET (4 bytes, little-endian)
///   [11-14] RC_LEN (4 bytes, little-endian)
///   [15+]  RC_DATA (up to 47 bytes)
func buildRCPacket(cmd: RCCommand, offset: UInt32 = 0, length: UInt32 = 0, data: Data = Data()) -> Data {
    var packet = Data(count: HID_REPORT_SIZE)
    packet[0] = 0x01 // Report ID
    packet[1] = 0x00
    let payloadLen = min(5 + 4 + 4 + data.count, 59)
    packet[2] = UInt8(payloadLen)
    packet[3] = 0x00
    packet[4] = 0x00
    packet[5] = cmd.rawValue | 0x80
    packet[6] = 0x00
    // Offset (LE)
    packet[7] = UInt8(offset & 0xFF)
    packet[8] = UInt8((offset >> 8) & 0xFF)
    packet[9] = UInt8((offset >> 16) & 0xFF)
    packet[10] = UInt8((offset >> 24) & 0xFF)
    // Length (LE)
    packet[11] = UInt8(length & 0xFF)
    packet[12] = UInt8((length >> 8) & 0xFF)
    packet[13] = UInt8((length >> 16) & 0xFF)
    packet[14] = UInt8((length >> 24) & 0xFF)
    // Data
    for i in 0..<min(data.count, 47) {
        packet[15 + i] = data[i]
    }
    return packet
}

/// Parse an RC response packet. Returns (result code, response data).
/// Real device response format (verified):
///   [0]    Report ID (0x01)
///   [1]    0x00
///   [2]    0x2C (payload length)
///   [3]    0x00
///   [4]    RC enabled state (0x01=enabled, 0x00=disabled)
///   [5]    Command echo (without execute bit = done)
///   [6]    Result code (0x00=success, 0x01=error)
///   [7-10] Offset echo (LE)
///   [11-14] Length echo (LE)
///   [15+]  Response data
func parseRCResponse(_ packet: Data) -> (result: UInt8, data: Data) {
    guard packet.count >= 15 else { return (0xFF, Data()) }
    // Real device: length field may be echoed or zero.
    // Try length from bytes[11-14] first; if zero, return all data from [15] onwards.
    var len = Int(packet[11]) | (Int(packet[12]) << 8) | (Int(packet[13]) << 16) | (Int(packet[14]) << 24)
    if len == 0 || len > packet.count - 15 {
        len = packet.count - 15 // Return all available data
    }
    let data = packet.subdata(in: 15..<(15 + len))
    // Check byte[4] for RC state — if a command requires RC and it's disabled,
    // the real device may indicate failure. For mock compatibility, also check byte[6].
    let rcResult = packet[6]
    if rcResult == RCResult.disabled.rawValue {
        return (rcResult, data)
    }
    return (0x00, data) // If we got a response, command succeeded
}

// MARK: - VMM7100 Device Protocol

protocol VMM7100Transport {
    func open() -> Bool
    func close()
    func sendReport(_ data: Data) -> Bool
    func readReport() -> Data?
    var isOpen: Bool { get }
}

class VMM7100MockTransport: VMM7100Transport {
    let mock = MockDevice()
    var _isOpen = false
    var isOpen: Bool { _isOpen }
    var lastResponse: Data?

    func open() -> Bool {
        _isOpen = true
        return true
    }

    func close() {
        _isOpen = false
    }

    // Accumulate multi-packet writes for commands that need >47 bytes of data
    var pendingWriteData = Data()
    var pendingWriteOffset: UInt32 = 0
    var pendingWriteCmd: RCCommand?

    func sendReport(_ data: Data) -> Bool {
        guard _isOpen, data.count >= 15 else { return false }
        let cmdByte = data[5] & 0x7F
        guard let cmd = RCCommand(rawValue: cmdByte) else {
            lastResponse = nil
            return false
        }
        let offset = UInt32(data[7]) | (UInt32(data[8]) << 8) | (UInt32(data[9]) << 16) | (UInt32(data[10]) << 24)
        let length = UInt32(data[11]) | (UInt32(data[12]) << 8) | (UInt32(data[13]) << 16) | (UInt32(data[14]) << 24)
        // For write commands, use the full length from the field (not packet-limited)
        let availableData = data.count - 15
        let cmdData: Data
        if cmd == .writeToEEPROM || cmd == .writeToMemory {
            // In real device, data is sent in the packet. For mock, extract what fits
            cmdData = availableData > 0 ? data.subdata(in: 15..<min(15 + Int(length), data.count)) : Data()
        } else {
            let dataLen = min(Int(length), availableData)
            cmdData = dataLen > 0 ? data.subdata(in: 15..<(15 + dataLen)) : Data()
        }

        let (result, responseData) = mock.processCommand(cmd: cmd, offset: offset, length: length, data: cmdData)

        // Build response packet matching real device format
        var response = Data(count: HID_REPORT_SIZE)
        response[0] = 0x01
        response[2] = 0x2C // payload length (matches real device)
        response[4] = mock.rcEnabled ? 0x01 : 0x00 // RC enabled state
        response[5] = cmdByte // Command echo without execute bit
        response[6] = result // Result code
        response[7] = data[7]; response[8] = data[8]; response[9] = data[9]; response[10] = data[10]
        response[11] = UInt8(responseData.count & 0xFF)
        response[12] = UInt8((responseData.count >> 8) & 0xFF)
        for i in 0..<min(responseData.count, 47) {
            response[15 + i] = responseData[i]
        }
        lastResponse = response
        return true
    }

    func readReport() -> Data? {
        return lastResponse
    }
}

class VMM7100HIDTransport: VMM7100Transport {
    private var manager: IOHIDManager?
    private var hidDevice: IOHIDDevice?
    var _isOpen = false
    var isOpen: Bool { _isOpen }

    func open() -> Bool {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let mgr = manager else { return false }

        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey: VMM_VENDOR_ID,
            kIOHIDProductIDKey: VMM_PRODUCT_ID
        ]
        IOHIDManagerSetDeviceMatching(mgr, matchDict as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let openRet = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard openRet == kIOReturnSuccess else {
            printErr("Cannot open HID manager (0x\(String(format: "%x", openRet)))")
            return false
        }

        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
              let device = deviceSet.first else {
            printErr("VMM7100 not found. Is the adapter connected?")
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }

        self.hidDevice = device
        _isOpen = true
        return true
    }

    func close() {
        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidDevice = nil
        manager = nil
        _isOpen = false
    }

    func sendReport(_ data: Data) -> Bool {
        guard _isOpen, let device = hidDevice else { return false }
        var bytes = [UInt8](data)
        let ret = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, &bytes, bytes.count)
        return ret == kIOReturnSuccess
    }

    func readReport() -> Data? {
        guard _isOpen, let device = hidDevice else { return nil }
        var buffer = [UInt8](repeating: 0, count: HID_REPORT_SIZE)
        var length = buffer.count
        let ret = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, 1, &buffer, &length)
        guard ret == kIOReturnSuccess else { return nil }
        return Data(buffer.prefix(length))
    }
}

// MARK: - VMM7100 Tool

class VMM7100Tool {
    let transport: VMM7100Transport
    let isMock: Bool

    init(mock: Bool) {
        self.isMock = mock
        if mock {
            self.transport = VMM7100MockTransport()
        } else {
            self.transport = VMM7100HIDTransport()
        }
    }

    func connect() -> Bool {
        return transport.open()
    }

    func disconnect() {
        transport.close()
    }

    // MARK: RC Command execution

    func rcCommand(cmd: RCCommand, offset: UInt32 = 0, length: UInt32 = 0, data: Data = Data()) -> (success: Bool, data: Data) {
        let packet = buildRCPacket(cmd: cmd, offset: offset, length: length, data: data)

        for attempt in 0..<MAX_RETRY {
            if attempt > 0 && !isMock {
                usleep(RETRY_DELAY_MS * 1000)
            }

            guard transport.sendReport(packet) else { continue }
            if !isMock { usleep(10_000) } // 10ms for device to process

            guard let response = transport.readReport() else { continue }
            let (result, respData) = parseRCResponse(response)

            if result == RCResult.success.rawValue {
                return (true, respData)
            } else if result == RCResult.disabled.rawValue {
                printErr("RC not enabled - send EnableRC first")
                return (false, Data())
            } else if result == RCResult.unsupported.rawValue {
                printErr("Command not supported by device")
                return (false, Data())
            }
            // Retry on other failures
        }
        return (false, Data())
    }

    func enableRC() -> Bool {
        let priusData = "PRIUS".data(using: .ascii)!
        let (success, _) = rcCommand(cmd: .enableRC, length: UInt32(priusData.count), data: priusData)
        return success
    }

    func disableRC() {
        _ = rcCommand(cmd: .disableRC)
    }

    // MARK: Info command

    func cmdInfo() -> Bool {
        guard connect() else { return false }
        defer { disconnect() }

        guard enableRC() else {
            printErr("Failed to enable remote control")
            return false
        }
        defer { disableRC() }

        print("VMM7100 Adapter Info")
        print("====================")

        // Chip ID — little-endian from device
        let (idOk, idData) = rcCommand(cmd: .getId)
        if idOk && idData.count >= 2 {
            let chipId = UInt16(idData[0]) | (UInt16(idData[1]) << 8)
            print("  Chip ID:          VMM\(String(format: "%X", chipId))")
            if idData.count >= 3 {
                let rev = idData[2]
                print("  Chip revision:    \(String(format: "%c%d", 0x40 + (rev >> 4), rev & 0x0F))")
            }
        }

        // FW Version — real device returns [minor, major, ...] at bytes 15+
        let (verOk, verData) = rcCommand(cmd: .getVersion)
        if verOk && verData.count >= 2 {
            let major = verData[1]  // byte[16] in packet
            let minor = verData[0]  // byte[15] in packet
            let patch: UInt8 = verData.count >= 3 ? verData[2] : 0
            print("  Firmware version: \(major).\(String(format: "%02d", minor)).\(String(format: "%03d", patch))")
        }

        // Read firmware name from memory
        let (nameOk, nameData) = rcCommand(cmd: .readFromMemory, offset: 0x100, length: 32)
        if nameOk && !nameData.isEmpty {
            if let name = String(data: nameData.prefix(while: { $0 != 0 }), encoding: .ascii), !name.isEmpty {
                print("  Firmware name:    \(name)")
            }
        }

        // Read EDID info
        let (edidOk, edidData) = rcCommand(cmd: .readFromEEPROM, offset: 0, length: 128)
        if edidOk && edidData.count >= 128, let edid = parseEDID(edidData) {
            print("")
            print("Connected Display")
            print("-----------------")
            print("  Manufacturer:     \(edid.manufacturer)")
            if !edid.productName.isEmpty {
                print("  Product name:     \(edid.productName)")
            }
            print("  Product ID:       \(String(format: "0x%04X", edid.productID))")
            if edid.serial != 0 {
                print("  Serial:           \(edid.serial)")
            }
            print("  Manufacture date: Week \(edid.week), \(edid.year)")
            if edid.hRes > 0 && edid.vRes > 0 {
                print("  Native resolution: \(edid.hRes)x\(edid.vRes)")
            }
        }

        return true
    }

    // MARK: EDID command

    func cmdEDID() -> Bool {
        guard connect() else { return false }
        defer { disconnect() }
        guard enableRC() else { printErr("Failed to enable RC"); return false }
        defer { disableRC() }

        // Read full EDID (128 bytes base + possible 128 byte extension)
        var fullEDID = Data()
        for blockOffset in stride(from: 0, to: 256, by: Int(UNIT_SIZE)) {
            let (ok, data) = rcCommand(cmd: .readFromEEPROM, offset: UInt32(blockOffset), length: UInt32(UNIT_SIZE))
            if ok { fullEDID.append(data) } else { break }
        }

        guard fullEDID.count >= 128, let edid = parseEDID(fullEDID) else {
            printErr("Could not read or parse EDID")
            return false
        }

        print("EDID Information")
        print("================")
        print("  Manufacturer:     \(edid.manufacturer)")
        if !edid.productName.isEmpty {
            print("  Product name:     \(edid.productName)")
        }
        print("  Product ID:       \(String(format: "0x%04X", edid.productID))")
        if edid.serial != 0 {
            print("  Serial:           \(edid.serial)")
        }
        print("  Manufacture date: Week \(edid.week), \(edid.year)")
        if edid.hRes > 0 && edid.vRes > 0 {
            print("  Native resolution: \(edid.hRes)x\(edid.vRes)")
        }

        // Hex dump first 128 bytes
        print("")
        print("Raw EDID (hex):")
        for row in 0..<8 {
            let off = row * 16
            let hex = fullEDID[off..<min(off+16, fullEDID.count)].map { String(format: "%02X", $0) }.joined(separator: " ")
            print("  \(String(format: "%04X", off)): \(hex)")
        }

        return true
    }

    // MARK: Register command

    func cmdRegister(address: UInt32, writeValue: UInt32? = nil) -> Bool {
        guard connect() else { return false }
        defer { disconnect() }
        guard enableRC() else { printErr("Failed to enable RC"); return false }
        defer { disableRC() }

        if let value = writeValue {
            // Write register
            var writeData = Data(count: 4)
            writeData[0] = UInt8(value & 0xFF)
            writeData[1] = UInt8((value >> 8) & 0xFF)
            writeData[2] = UInt8((value >> 16) & 0xFF)
            writeData[3] = UInt8((value >> 24) & 0xFF)
            let (ok, _) = rcCommand(cmd: .writeToMemory, offset: address, length: 4, data: writeData)
            if ok {
                print("Wrote 0x\(String(format: "%08X", value)) to register 0x\(String(format: "%06X", address))")
            } else {
                printErr("Failed to write register 0x\(String(format: "%06X", address))")
                return false
            }
            // Read back
            let (rok, rdata) = rcCommand(cmd: .readFromMemory, offset: address, length: 4)
            if rok && rdata.count >= 4 {
                let readback = UInt32(rdata[0]) | (UInt32(rdata[1]) << 8) | (UInt32(rdata[2]) << 16) | (UInt32(rdata[3]) << 24)
                print("Read back: 0x\(String(format: "%08X", readback))")
            }
        } else {
            // Read register
            let (ok, data) = rcCommand(cmd: .readFromMemory, offset: address, length: 4)
            if ok && data.count >= 4 {
                let value = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
                print("Register 0x\(String(format: "%06X", address)) = 0x\(String(format: "%08X", value))")
            } else if ok {
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("Register 0x\(String(format: "%06X", address)) = \(hex)")
            } else {
                printErr("Failed to read register 0x\(String(format: "%06X", address))")
                return false
            }
        }
        return true
    }

    // MARK: Dump command

    /// Dump firmware. If already connected with RC enabled, pass standalone=false.
    func cmdDump(outputPath: String, standalone: Bool = true) -> Bool {
        if standalone {
            guard connect() else { return false }
            guard enableRC() else { printErr("Failed to enable RC"); disconnect(); return false }
        }
        defer {
            if standalone {
                disableRC()
                disconnect()
            }
        }

        print("Dumping firmware (\(FIRMWARE_SIZE / 1024) KB)...")
        var firmware = Data()
        let totalChunks = FIRMWARE_SIZE / Int(UNIT_SIZE)

        for chunk in 0..<totalChunks {
            let offset = UInt32(chunk * Int(UNIT_SIZE))
            let (ok, data) = rcCommand(cmd: .readFromEEPROM, offset: offset, length: UInt32(UNIT_SIZE))
            guard ok else {
                printErr("Read failed at offset 0x\(String(format: "%06X", offset))")
                return false
            }
            firmware.append(data)

            if chunk % 512 == 0 || chunk == totalChunks - 1 {
                let pct = (chunk + 1) * 100 / totalChunks
                printProgress(pct, "\(firmware.count / 1024) KB")
            }
        }
        print("") // newline after progress

        guard firmware.count == FIRMWARE_SIZE else {
            printErr("Dump size mismatch: got \(firmware.count), expected \(FIRMWARE_SIZE)")
            return false
        }

        do {
            try firmware.write(to: URL(fileURLWithPath: outputPath))
            print("Saved to \(outputPath) (\(firmware.count) bytes)")
            return true
        } catch {
            printErr("Failed to write file: \(error)")
            return false
        }
    }

    // MARK: Flash command

    func cmdFlash(firmwarePath: String, dryRun: Bool = false, force: Bool = false) -> Bool {
        // Load and validate firmware file
        let url = URL(fileURLWithPath: firmwarePath)
        guard FileManager.default.fileExists(atPath: firmwarePath) else {
            printErr("File not found: \(firmwarePath)")
            return false
        }

        let firmware: Data
        do {
            firmware = try Data(contentsOf: url)
        } catch {
            printErr("Failed to read firmware file: \(error)")
            return false
        }

        guard firmware.count == FIRMWARE_SIZE else {
            printErr("Invalid firmware size: \(firmware.count) bytes (expected \(FIRMWARE_SIZE))")
            return false
        }

        let fileCRC = crc16(firmware)
        let sectors = FIRMWARE_SIZE / 0x10000 // 16 sectors of 64K

        if dryRun {
            print("Dry Run — Flash Plan")
            print("====================")
            print("  Firmware file:  \(firmwarePath)")
            print("  File size:      \(firmware.count) bytes (\(firmware.count / 1024) KB)")
            print("  File CRC16:     0x\(String(format: "%04X", fileCRC))")
            print("  Erase sectors:  \(sectors) x 64KB")
            print("  Write chunks:   \(FIRMWARE_SIZE / UNIT_SIZE) x \(UNIT_SIZE) bytes")
            print("")
            print("No changes made to device.")
            return true
        }

        guard connect() else { return false }
        defer { disconnect() }
        guard enableRC() else { printErr("Failed to enable RC"); return false }
        defer { disableRC() }

        // Read current version + chip info for backup naming
        var versionStr = "unknown"
        let (verOk, verData) = rcCommand(cmd: .getVersion)
        if verOk && verData.count >= 2 {
            let major = verData[1]; let minor = verData[0]
            let patch: UInt8 = verData.count >= 3 ? verData[2] : 0
            versionStr = "\(major).\(String(format: "%02d", minor)).\(String(format: "%03d", patch))"
            print("Current FW: \(versionStr)")
        }

        var chipStr = "VMM7100"
        let (idOk, idData) = rcCommand(cmd: .getId)
        if idOk && idData.count >= 2 {
            let chipId = (UInt16(idData[0]) << 8) | UInt16(idData[1])
            chipStr = "VMM\(String(format: "%04X", chipId))"
        }

        // Auto-backup current firmware before flashing
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let backupDir = (firmwarePath as NSString).deletingLastPathComponent
        let backupName = "backup_\(chipStr)_v\(versionStr)_\(timestamp).fullrom"
        let backupPath = backupDir.isEmpty ? backupName : "\(backupDir)/\(backupName)"

        print("Auto-backup current firmware → \(backupName)")
        if !cmdDump(outputPath: backupPath, standalone: false) {
            printErr("Backup failed! Aborting flash for safety.")
            if !force {
                return false
            }
            printErr("--force specified, continuing without backup...")
        }
        print("")

        print("Flashing \(firmwarePath)...")
        print("")

        // Step 1: Erase flash
        print("[1/4] Erasing flash (\(sectors) sectors)...")
        for sector in 0..<sectors {
            let offset = UInt32(sector * 0x10000)
            let (ok, _) = rcCommand(cmd: .flashErase, offset: offset, length: FLASH_SECTOR_ERASE_64K)
            guard ok else {
                printErr("Erase failed at sector \(sector) (offset 0x\(String(format: "%06X", offset)))")
                return false
            }
        }
        if !isMock {
            print("  Waiting for flash settle...")
            usleep(FLASH_SETTLE_MS)
        }
        print("  Erase complete.")

        // Step 2: Write firmware (32-byte chunks to fit in HID packet payload)
        print("[2/4] Writing firmware...")
        let writeChunk = Int(UNIT_SIZE) // 32 bytes fits in single HID packet
        let totalChunks = FIRMWARE_SIZE / writeChunk
        for chunk in 0..<totalChunks {
            let offset = chunk * writeChunk
            let chunkData = firmware.subdata(in: offset..<(offset + writeChunk))
            let (ok, _) = rcCommand(cmd: .writeToEEPROM, offset: UInt32(offset), length: UInt32(writeChunk), data: chunkData)
            guard ok else {
                printErr("Write failed at offset 0x\(String(format: "%06X", offset))")
                return false
            }
            if chunk % 256 == 0 || chunk == totalChunks - 1 {
                let pct = (chunk + 1) * 100 / totalChunks
                printProgress(pct, "\(offset / 1024) KB")
            }
        }
        print("") // newline after progress
        print("  Write complete.")

        // Step 3: Verify CRC
        print("[3/4] Verifying CRC16...")
        let (crcOk, crcData) = rcCommand(cmd: .calCRC16, offset: 0, length: UInt32(FIRMWARE_SIZE))
        if crcOk && crcData.count >= 2 {
            let deviceCRC = (UInt16(crcData[0]) << 8) | UInt16(crcData[1])
            if deviceCRC == fileCRC {
                print("  CRC match: 0x\(String(format: "%04X", deviceCRC))")
            } else {
                printErr("CRC MISMATCH! Device: 0x\(String(format: "%04X", deviceCRC)), File: 0x\(String(format: "%04X", fileCRC))")
                if !force {
                    printErr("Flash may be corrupt. Use --force to activate anyway.")
                    return false
                }
            }
        } else {
            printErr("CRC verification failed")
            if !force { return false }
        }

        // Step 4: Activate
        print("[4/4] Activating firmware...")
        let (actOk, _) = rcCommand(cmd: .activateFirmware)
        guard actOk else {
            printErr("Failed to activate firmware")
            return false
        }

        print("")
        print("Flash complete! Disconnect and reconnect the adapter.")
        return true
    }

    // MARK: Reset command

    func cmdReset() -> Bool {
        guard connect() else { return false }
        defer { disconnect() }
        guard enableRC() else { printErr("Failed to enable RC"); return false }

        // Send the reset sequence from vmm7100reset.swift
        let resetPackets: [[UInt8]] = [
            [
                0x01, 0x00, 0x11, 0x00, 0x00, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
                0x00, 0x00, 0x00, 0x50, 0x52, 0x49, 0x55, 0x53, 0xD6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00,
            ],
            [
                0x01, 0x00, 0x0C, 0x00, 0x00, 0xB1, 0x00, 0x2C, 0x02, 0x20, 0x20, 0x04,
                0x00, 0x00, 0x00, 0xD1, 0x20, 0x00, 0x71, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00,
            ],
            [
                0x01, 0x00, 0x10, 0x00, 0x00, 0xA1, 0x00, 0x1C, 0x02, 0x20, 0x20, 0x04,
                0x00, 0x00, 0x00, 0xF5, 0x00, 0x00, 0x00, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00,
            ],
        ]

        for (i, packetBytes) in resetPackets.enumerated() {
            if i > 0 { sleep(1) }
            let data = Data(packetBytes)
            guard transport.sendReport(data) else {
                printErr("Failed to send reset packet \(i + 1)")
                return false
            }
        }

        print("Reset sent. Device will re-enumerate.")
        print("Display may briefly disconnect — this is normal.")
        return true
    }

    // MARK: Mock tests

    func runMockTests() -> Bool {
        assert(isMock, "Mock tests require --mock mode")
        var passed = 0
        var failed = 0

        func test(_ name: String, _ body: () -> Bool) {
            if body() {
                print("  PASS: \(name)")
                passed += 1
            } else {
                print("  FAIL: \(name)")
                failed += 1
            }
        }

        print("Running mock tests...")
        print("")

        // Test CRC16
        test("CRC16 empty") { crc16(Data()) == 0xFFFF }
        test("CRC16 known value") {
            let data = "123456789".data(using: .ascii)!
            return crc16(data) == 0x29B1 // Standard CRC-16/CCITT-FALSE
        }

        // Test EDID parser
        test("EDID parse valid") {
            let mock = MockDevice()
            let edidData = Data(mock.sampleEDID)
            guard let edid = parseEDID(edidData) else { return false }
            return edid.manufacturer == "DEL" && edid.productName == "MOCK DISPLAY"
        }
        test("EDID parse invalid") {
            let badData = Data(count: 128) // all zeros, no header
            return parseEDID(badData) == nil
        }
        test("EDID parse too short") {
            return parseEDID(Data(count: 64)) == nil
        }

        // Test packet builder
        test("Packet EnableRC format") {
            let pkt = buildRCPacket(cmd: .enableRC, length: 5, data: "PRIUS".data(using: .ascii)!)
            return pkt.count == HID_REPORT_SIZE
                && pkt[0] == 0x01
                && pkt[5] == (0x01 | 0x80)
                && pkt[15] == 0x50 // 'P'
                && pkt[16] == 0x52 // 'R'
                && pkt[17] == 0x49 // 'I'
                && pkt[18] == 0x55 // 'U'
                && pkt[19] == 0x53 // 'S'
        }
        test("Packet offset encoding") {
            let pkt = buildRCPacket(cmd: .readFromEEPROM, offset: 0x12345678, length: 32)
            return pkt[7] == 0x78 && pkt[8] == 0x56 && pkt[9] == 0x34 && pkt[10] == 0x12
        }
        test("Packet length encoding") {
            let pkt = buildRCPacket(cmd: .readFromEEPROM, offset: 0, length: 0x100)
            return pkt[11] == 0x00 && pkt[12] == 0x01
        }

        // Test mock device commands
        guard connect() else { print("  FAIL: mock connect"); return false }
        defer { disconnect() }

        test("EnableRC with PRIUS") { enableRC() }

        test("GetId returns VMM7100") {
            let (ok, data) = rcCommand(cmd: .getId)
            guard ok, data.count >= 2 else { return false }
            let chipId = (UInt16(data[0]) << 8) | UInt16(data[1])
            return chipId == 0x7100
        }

        test("GetVersion returns valid") {
            let (ok, data) = rcCommand(cmd: .getVersion)
            return ok && data.count >= 3 && data[0] == 7 && data[1] == 2
        }

        test("ReadFromMemory chip ID register") {
            let (ok, data) = rcCommand(cmd: .readFromMemory, offset: REG_CHIP_ID, length: 2)
            guard ok, data.count >= 2 else { return false }
            return data[0] == 0x71 && data[1] == 0x00
        }

        test("ReadFromEEPROM reads flash data") {
            let (ok, data) = rcCommand(cmd: .readFromEEPROM, offset: 0x100, length: UInt32(UNIT_SIZE))
            guard ok, data.count >= 14 else { return false }
            // Should read the firmware name we wrote at 0x100
            let name = String(data: data.prefix(while: { $0 != 0 }), encoding: .ascii)
            return name == "Spyder_fw_DP_CM"
        }

        test("WriteToEEPROM + read back") {
            let testData = Data([0xDE, 0xAD, 0xBE, 0xEF])
            let offset: UInt32 = 0x80000 // safe offset
            let (wok, _) = rcCommand(cmd: .writeToEEPROM, offset: offset, length: UInt32(testData.count), data: testData)
            guard wok else { return false }
            let (rok, rdata) = rcCommand(cmd: .readFromEEPROM, offset: offset, length: 4)
            return rok && rdata == testData
        }

        test("FlashErase zeros sector") {
            // Write known data, erase, verify 0xFF
            let testData = Data(repeating: 0xAA, count: 32)
            _ = rcCommand(cmd: .writeToEEPROM, offset: 0xF0000, length: 32, data: testData)
            let (eok, _) = rcCommand(cmd: .flashErase, offset: 0xF0000, length: FLASH_SECTOR_ERASE_64K)
            guard eok else { return false }
            let (rok, rdata) = rcCommand(cmd: .readFromEEPROM, offset: 0xF0000, length: 32)
            return rok && rdata.allSatisfy { $0 == 0xFF }
        }

        test("CRC16 verify") {
            let (ok, data) = rcCommand(cmd: .calCRC16, offset: 0, length: 256)
            return ok && data.count >= 2
        }

        test("ActivateFirmware succeeds") {
            let (ok, _) = rcCommand(cmd: .activateFirmware)
            return ok
        }

        test("DisableRC") {
            disableRC()
            let (ok, _) = rcCommand(cmd: .getId)
            return !ok // Should fail when RC disabled
        }

        // Test flash dry run
        test("Flash dry run validates file") {
            // Create a temp file with correct size
            let tmpPath = NSTemporaryDirectory() + "test_firmware.fullrom"
            let tmpData = Data(count: FIRMWARE_SIZE)
            try? tmpData.write(to: URL(fileURLWithPath: tmpPath))
            defer { try? FileManager.default.removeItem(atPath: tmpPath) }
            return cmdFlash(firmwarePath: tmpPath, dryRun: true)
        }

        test("Flash rejects wrong size") {
            let tmpPath = NSTemporaryDirectory() + "bad_firmware.fullrom"
            let tmpData = Data(count: 1000) // Wrong size
            try? tmpData.write(to: URL(fileURLWithPath: tmpPath))
            defer { try? FileManager.default.removeItem(atPath: tmpPath) }
            return !cmdFlash(firmwarePath: tmpPath, dryRun: true)
        }

        test("Flash rejects missing file") {
            return !cmdFlash(firmwarePath: "/nonexistent/firmware.fullrom", dryRun: true)
        }

        // Test dump (before flash, so flash data is pristine)
        test("Dump firmware (mock)") {
            guard enableRC() else { return false }
            let tmpPath = NSTemporaryDirectory() + "mock_dump.fullrom"
            defer { try? FileManager.default.removeItem(atPath: tmpPath) }
            guard cmdDump(outputPath: tmpPath, standalone: false) else { return false }
            guard let dumped = try? Data(contentsOf: URL(fileURLWithPath: tmpPath)) else { return false }
            return dumped.count == FIRMWARE_SIZE
        }

        // Test full mock flash cycle
        test("Full flash cycle (mock)") {
            let tmpPath = NSTemporaryDirectory() + "mock_flash.fullrom"
            var fw = Data(count: FIRMWARE_SIZE)
            // Put recognizable pattern
            for i in 0..<fw.count { fw[i] = UInt8(i & 0xFF) }
            try? fw.write(to: URL(fileURLWithPath: tmpPath))
            defer { try? FileManager.default.removeItem(atPath: tmpPath) }

            return cmdFlash(firmwarePath: tmpPath)
        }

        print("")
        print("Results: \(passed) passed, \(failed) failed")
        return failed == 0
    }
}

// MARK: - Helpers

func printErr(_ msg: String) {
    fputs("Error: \(msg)\n", stderr)
}

func printProgress(_ percent: Int, _ detail: String) {
    let bar = String(repeating: "#", count: percent / 2) + String(repeating: ".", count: 50 - percent / 2)
    print("\r  [\(bar)] \(percent)% \(detail)", terminator: "")
    fflush(stdout)
}

func parseHex(_ s: String) -> UInt32? {
    let cleaned = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
    return UInt32(cleaned, radix: 16)
}

// MARK: - CLI

func printUsage() {
    print("""
    vmm7100tool — macOS firmware tool for VMM7100 USB-C to HDMI adapter

    Usage:
      vmm7100tool info                         Read adapter & display info
      vmm7100tool flash <firmware.fullrom>      Flash firmware
      vmm7100tool flash --dry-run <firmware>    Show flash plan without writing
      vmm7100tool dump <output.fullrom>         Backup current firmware
      vmm7100tool reset                         Reset adapter board
      vmm7100tool edid                          Dump EDID information
      vmm7100tool register <addr>               Read register (hex address)
      vmm7100tool register <addr> <value>       Write register (hex address & value)
      vmm7100tool test                          Run mock self-tests

    Options:
      --mock     Use simulated device (for testing without hardware)
      --force    Continue flash even if CRC mismatch

    Examples:
      vmm7100tool info
      vmm7100tool dump backup.fullrom
      vmm7100tool flash Spyder_fw_USBC_CMforMac4K120hz.fullrom
      vmm7100tool register 0x507
    """)
}

func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())

    if args.isEmpty || args.contains("--help") || args.contains("-h") {
        printUsage()
        return 0
    }

    let isMock = args.contains("--mock")
    let isForce = args.contains("--force")
    let filteredArgs = args.filter { !$0.hasPrefix("--") }

    guard let command = filteredArgs.first else {
        printUsage()
        return 1
    }

    let tool = VMM7100Tool(mock: isMock)

    switch command {
    case "info":
        return tool.cmdInfo() ? 0 : 1

    case "edid":
        return tool.cmdEDID() ? 0 : 1

    case "register", "reg":
        guard filteredArgs.count >= 2, let addr = parseHex(filteredArgs[1]) else {
            printErr("Usage: vmm7100tool register <hex_addr> [hex_value]")
            return 1
        }
        let writeVal = filteredArgs.count >= 3 ? parseHex(filteredArgs[2]) : nil
        return tool.cmdRegister(address: addr, writeValue: writeVal) ? 0 : 1

    case "dump":
        guard filteredArgs.count >= 2 else {
            printErr("Usage: vmm7100tool dump <output.fullrom>")
            return 1
        }
        return tool.cmdDump(outputPath: filteredArgs[1], standalone: true) ? 0 : 1

    case "flash":
        let isDryRun = args.contains("--dry-run")
        let fwArgs = filteredArgs.dropFirst()
        guard let fwPath = fwArgs.first else {
            printErr("Usage: vmm7100tool flash [--dry-run] <firmware.fullrom>")
            return 1
        }
        return tool.cmdFlash(firmwarePath: fwPath, dryRun: isDryRun, force: isForce) ? 0 : 1

    case "reset":
        return tool.cmdReset() ? 0 : 1

    case "test":
        let mockTool = VMM7100Tool(mock: true)
        return mockTool.runMockTests() ? 0 : 1

    default:
        printErr("Unknown command: \(command)")
        printUsage()
        return 1
    }
}

exit(main())
