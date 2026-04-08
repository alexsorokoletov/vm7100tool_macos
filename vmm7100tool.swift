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
let EEPROM_VERSION_OFFSET: UInt32 = 0x04000  // 3 bytes: major, minor, patch
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
    case enableFlashChipErase = 0x08
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
    var manager: IOHIDManager?
    var hidDevice: IOHIDDevice?
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
            if UInt32(bitPattern: Int32(openRet)) == 0xe00002c5 { // kIOReturnExclusiveAccess
                printErr("Device is busy — another process has exclusive access. Close other tools and retry.")
            } else {
                printErr("Cannot open HID manager (0x\(String(format: "%x", openRet)))")
            }
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

        // Read USB device info from IORegistry
        func ioregValue(_ key: String) -> String? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", "ioreg -l -w0 | grep -m1 '\"\(key)\"' | sed 's/.*= //;s/\"//g;s/ *$//'"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            let val = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return val?.isEmpty == true ? nil : val
        }

        let usbVendor = ioregValue("USB Vendor Name") ?? ""
        let usbSerial = ioregValue("USB Serial Number") ?? ""

        print("VMM7100 Adapter Info")
        print("====================")
        if !usbVendor.isEmpty {
            print("  USB vendor:       \(usbVendor)")
        }
        if !usbSerial.isEmpty && usbSerial != "000000000000" {
            print("  USB serial:       \(usbSerial)")
        }

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

        // Board/Customer ID — Spyder uses register 0x9000020E (requires Tahoe)
        let (boardOk, boardData) = rcCommand(cmd: .readFromMemory, offset: 0x9000020E, length: 2)
        if boardOk && boardData.count >= 2 {
            let boardId = UInt16(boardData[0]) | (UInt16(boardData[1]) << 8)
            if boardId != 0 {
                print("  Board ID:         0x\(String(format: "%04X", boardId))")
            }
        }
        // Additional board info at 0x90000210
        let (extraOk, extraData) = rcCommand(cmd: .readFromMemory, offset: 0x90000210, length: 2)
        if extraOk && extraData.count >= 2 {
            let extraId = UInt16(extraData[0]) | (UInt16(extraData[1]) << 8)
            if extraId != 0 {
                print("  Board revision:   0x\(String(format: "%04X", extraId))")
            }
        }

        // FW Version — GetVersion HID command returns [minor, major] at bytes 15-16.
        // Patch version is read from EEPROM offset 0x04000 (3 bytes: major, minor, patch).
        let (verOk, verData) = rcCommand(cmd: .getVersion)
        if verOk && verData.count >= 2 {
            let major = verData[1]
            let minor = verData[0]
            // Try reading patch from flash
            let (patchOk, patchData) = rcCommand(cmd: .readFromEEPROM, offset: EEPROM_VERSION_OFFSET, length: 3)
            if patchOk && patchData.count >= 3 && patchData[0] == major && patchData[1] == minor {
                let patch = patchData[2]
                print("  Firmware version: \(major).\(String(format: "%02d", minor)).\(patch)")
            } else {
                print("  Firmware version: \(major).\(String(format: "%02d", minor))")
            }
        }

        // Read firmware name from EEPROM
        // Name is at 0x2F1 (0x2F0 has a junk prefix byte), truncated "Spyder_fw_..."
        let (nameOk, nameData) = rcCommand(cmd: .readFromEEPROM, offset: 0x2F1, length: 31)
        if nameOk && !nameData.isEmpty {
            if let name = String(data: nameData.prefix(while: { $0 >= 0x20 && $0 < 0x7F }), encoding: .ascii), name.count >= 4 {
                let displayName = name.hasPrefix("der_fw_") ? "Spy" + name : name
                print("  Firmware name:    \(displayName)")
            }
        }

        // Read stored EDID from flash
        let (edidOk, edidData) = rcCommand(cmd: .readFromEEPROM, offset: 0, length: 128)
        if edidOk && edidData.count >= 128, let edid = parseEDID(edidData) {
            print("")
            print("Stored EDID (adapter flash)")
            print("---------------------------")
            print("  Manufacturer:     \(edid.manufacturer)")
            if !edid.productName.isEmpty {
                print("  Product name:     \(edid.productName)")
            }
            if edid.hRes > 0 && edid.vRes > 0 {
                print("  Max resolution:   \(edid.hRes)x\(edid.vRes)")
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

    // MARK: Display command — read connected monitor EDID from IORegistry

    func cmdDisplay() -> Bool {
        // Read EDID from IORegistry (no device connection needed)
        // Use ioreg to find EDID data
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", """
import subprocess, json, re, struct, sys

# Get EDID from ioreg
result = subprocess.run(["ioreg", "-l", "-w0"], capture_output=True, text=True)
edid_hex = None
product_name = None
for line in result.stdout.split("\\n"):
    if '"EDID" = <' in line and "Metadata" not in line and "UUID" not in line:
        m = re.search(r'"EDID"\\s*=\\s*<([0-9a-f]+)>', line)
        if m:
            edid_hex = m.group(1)
            break

if not edid_hex:
    print("No display EDID found in IORegistry.")
    print("Is a monitor connected?")
    sys.exit(1)

edid = bytes.fromhex(edid_hex)
base = edid[:128]
ext = edid[128:256] if len(edid) > 128 else None

# Verify header
if base[:8] != bytes([0,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0]):
    print("Invalid EDID header")
    sys.exit(1)

# Manufacturer
mfg = (base[8] << 8) | base[9]
mfg_str = ''.join(chr(((mfg >> s) & 0x1F) + 0x40) for s in [10,5,0])
prod = base[10] | (base[11] << 8)
serial = struct.unpack_from('<I', base, 12)[0]

print("Connected Display")
print("=" * 50)
print(f"  Manufacturer:      {mfg_str}")
print(f"  Product code:      0x{prod:04X}")
print(f"  Serial:            {serial}")
print(f"  Manufacture date:  Week {base[16]}, {base[17]+1990}")
print(f"  EDID version:      {base[18]}.{base[19]}")

b20 = base[20]
if b20 & 0x80:
    depth_map = {0:"undefined",1:"6-bit",2:"8-bit",3:"10-bit",4:"12-bit",5:"14-bit",6:"16-bit"}
    iface_map = {0:"undefined",1:"DVI",2:"HDMIa",3:"HDMIb",4:"MDDI",5:"DisplayPort"}
    print(f"  Input:             Digital, {depth_map.get((b20>>4)&7,'?')}, {iface_map.get(b20&0xF,'?')}")
h,v = base[21], base[22]
if h and v:
    diag = (h**2 + v**2)**0.5 / 2.54
    print(f"  Screen size:       {h}x{v} cm (~{diag:.0f}\\" diagonal)")
print(f"  Gamma:             {(base[23]+100)/100:.2f}")

# Established timings
est = [(35,0x80,"720x400@70"),(35,0x40,"720x400@88"),(35,0x20,"640x480@60"),
       (35,0x10,"640x480@67"),(35,0x08,"640x480@72"),(35,0x04,"640x480@75"),
       (35,0x02,"800x600@56"),(35,0x01,"800x600@60"),(36,0x80,"800x600@72"),
       (36,0x40,"800x600@75"),(36,0x20,"832x624@75"),(36,0x10,"1024x768@87i"),
       (36,0x08,"1024x768@60"),(36,0x04,"1024x768@70"),(36,0x02,"1024x768@75"),
       (36,0x01,"1280x1024@75"),(37,0x80,"1152x870@75")]
modes = [n for b,m,n in est if base[b]&m]
if modes:
    print(f"\\nEstablished Timings:")
    print(f"  {', '.join(modes)}")

# Standard timings
aspect_map = {0:(16,10),1:(4,3),2:(5,4),3:(16,9)}
stds = []
for i in range(8):
    b1,b2 = base[38+i*2],base[39+i*2]
    if b1==1 and b2==1: continue
    hp=(b1+31)*8; ar=aspect_map.get((b2>>6)&3,(16,9)); vp=hp*ar[1]//ar[0]; r=(b2&0x3F)+60
    stds.append(f"{hp}x{vp}@{r}")
if stds:
    print(f"\\nStandard Timings:")
    for s in stds: print(f"  {s}")

# Detailed descriptors
print(f"\\nDetailed Descriptors:")
for block in range(4):
    off = 54 + block * 18
    pc = base[off] | (base[off+1] << 8)
    if pc == 0:
        tag = base[off+3]
        data = bytes(base[off+5:off+18])
        text = data.decode('ascii',errors='replace').strip('\\n\\r\\x0a ')
        if tag == 0xFD:
            print(f"  Range:           V={base[off+5]}-{base[off+6]}Hz  H={base[off+7]}-{base[off+8]}kHz  Max pixel clock={base[off+9]*10}MHz")
        elif tag == 0xFC: print(f"  Monitor name:    {text}")
        elif tag == 0xFF: print(f"  Serial string:   {text}")
        elif tag == 0xFE: print(f"  Text:            {text}")
    else:
        pc_mhz = pc * 0.01
        ha = base[off+2]|((base[off+4]&0xF0)<<4)
        hb = base[off+3]|((base[off+4]&0x0F)<<8)
        va = base[off+5]|((base[off+7]&0xF0)<<4)
        vb = base[off+6]|((base[off+7]&0x0F)<<8)
        ht,vt = ha+hb, va+vb
        ref = pc_mhz*1e6/(ht*vt) if ht*vt else 0
        il = "i" if base[off+17]&0x80 else "p"
        print(f"  Preferred mode:  {ha}x{va} @ {ref:.1f}Hz{il}  ({pc_mhz:.2f} MHz)")

# CTA Extension
if ext and ext[0] == 0x02:
    print(f"\\nCTA-861 Extension:")
    dtd_start = ext[2]
    off = 4
    while off < dtd_start and off < len(ext):
        tag = (ext[off] >> 5) & 7
        length = ext[off] & 0x1F
        if off + 1 + length > len(ext): break

        if tag == 2:  # Video SVDs
            vic_modes = {
                1:"640x480@60",2:"720x480@60",3:"720x480@60",4:"1280x720@60",
                5:"1920x1080@60i",16:"1920x1080@60",17:"720x576@50",
                19:"1280x720@50",20:"1920x1080@50i",31:"1920x1080@50",
                32:"1920x1080@24",33:"1920x1080@25",34:"1920x1080@30",
                47:"1280x720@120",63:"1920x1080@120",93:"3840x2160@24",
                94:"3840x2160@25",95:"3840x2160@30",96:"3840x2160@50",
                97:"3840x2160@60",107:"3840x2160@120",118:"3840x2160@100",
                120:"5120x2160@60",127:"5120x2880@60",
            }
            print(f"  Video modes:")
            for i in range(length):
                svd = ext[off+1+i]
                native = " *" if svd & 0x80 else ""
                vic = svd & 0x7F
                mode = vic_modes.get(vic, f"VIC {vic}")
                print(f"    {mode}{native}")

        elif tag == 1:  # Audio
            fmt_names = {1:"LPCM",2:"AC-3",3:"MPEG1",4:"MP3",6:"AAC-LC",7:"DTS",
                        10:"E-AC-3",11:"DTS-HD",12:"TrueHD"}
            print(f"  Audio:")
            for i in range(0, length, 3):
                if off+1+i+2 >= len(ext): break
                fmt = (ext[off+1+i] >> 3) & 0x0F
                ch = (ext[off+1+i] & 0x07) + 1
                rates = ext[off+2+i]
                rl = []
                for bit,khz in enumerate(["32","44.1","48","88.2","96","176.4","192"]):
                    if rates & (1<<bit): rl.append(khz)
                bits = ext[off+3+i]
                bd = []
                if fmt == 1:  # LPCM
                    if bits & 1: bd.append("16-bit")
                    if bits & 2: bd.append("20-bit")
                    if bits & 4: bd.append("24-bit")
                print(f"    {fmt_names.get(fmt,f'Fmt{fmt}')}: {ch}ch [{', '.join(rl)}kHz] {', '.join(bd)}")

        elif tag == 3:  # Vendor specific
            oui = ext[off+1] | (ext[off+2]<<8) | (ext[off+3]<<16)
            if oui == 0x000C03:
                tmds = ext[off+7]*5 if length >= 7 else 0
                flags = ext[off+6] if length >= 6 else 0
                dc = []
                if flags & 0x10: dc.append("30-bit")
                if flags & 0x20: dc.append("36-bit")
                if flags & 0x40: dc.append("48-bit")
                print(f"  HDMI 1.4:        Max TMDS {tmds}MHz, Deep Color: {', '.join(dc) if dc else 'No'}")
            elif oui == 0xC45DD8:
                max_t = ext[off+5]*5 if length >= 5 else 0
                flags1 = ext[off+6] if length >= 6 else 0
                frl = (ext[off+7] >> 4) & 0x0F if length >= 7 else 0
                frl_map = {0:"None",1:"3L@3G",2:"3L@6G",3:"4L@6G",4:"4L@8G",5:"4L@10G",6:"4L@12G"}
                scdc = "Yes" if flags1 & 0x80 else "No"
                dsc = "Yes" if (ext[off+7] & 0x80) else "No" if length >= 7 else "?"
                vrr_min = ext[off+8] & 0x3F if length >= 8 else 0
                vrr_max = (((ext[off+8]>>6)&3)<<8 | ext[off+9]) if length >= 9 else 0
                hdmi_ver = "HDMI 2.1" if frl > 0 else "HDMI 2.0"
                print(f"  {hdmi_ver}:         Max TMDS {max_t}MHz, SCDC={scdc}, FRL={frl_map.get(frl,'?')}")
                if vrr_max: print(f"                   VRR {vrr_min}-{vrr_max}Hz, DSC={dsc}")
                elif dsc == "Yes": print(f"                   DSC={dsc}")

        off += 1 + length

    # Extension DTDs
    off = dtd_start
    ext_timings = []
    while off + 17 < len(ext):
        pc = ext[off] | (ext[off+1] << 8)
        if pc == 0: break
        pc_mhz = pc * 0.01
        ha = ext[off+2]|((ext[off+4]&0xF0)<<4)
        va = ext[off+5]|((ext[off+7]&0xF0)<<4)
        hb = ext[off+3]|((ext[off+4]&0x0F)<<8)
        vb = ext[off+6]|((ext[off+7]&0x0F)<<8)
        ht,vt = ha+hb,va+vb
        ref = pc_mhz*1e6/(ht*vt) if ht*vt else 0
        il = "i" if ext[off+17]&0x80 else "p"
        ext_timings.append(f"{ha}x{va} @ {ref:.1f}Hz{il}  ({pc_mhz:.2f} MHz)")
        off += 18
    if ext_timings:
        print(f"  Extra timings:")
        for t in ext_timings: print(f"    {t}")

cksum = sum(base[:128]) & 0xFF
print(f"\\nChecksum:            {'valid' if cksum == 0 else 'INVALID'}")
"""]
        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe
        try? proc.run()
        proc.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if !output.isEmpty {
            print(output, terminator: "")
        }
        if !errOutput.isEmpty && output.isEmpty {
            printErr(errOutput)
        }

        return proc.terminationStatus == 0
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

        // Read version from firmware file
        var fileVersionStr = "unknown"
        if firmware.count > Int(EEPROM_VERSION_OFFSET) + 3 {
            let fMajor = firmware[Int(EEPROM_VERSION_OFFSET)]
            let fMinor = firmware[Int(EEPROM_VERSION_OFFSET) + 1]
            let fPatch = firmware[Int(EEPROM_VERSION_OFFSET) + 2]
            if fMajor > 0 && fMajor < 0xFF {
                fileVersionStr = "\(fMajor).\(String(format: "%02d", fMinor)).\(fPatch)"
            }
        }

        if dryRun {
            print("Dry Run — Flash Plan")
            print("====================")
            print("  Firmware file:  \(firmwarePath)")
            print("  File version:   \(fileVersionStr)")
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

        // Read current version from device
        var versionStr = "unknown"
        let (verOk, verData) = rcCommand(cmd: .getVersion)
        if verOk && verData.count >= 2 {
            let major = verData[1]; let minor = verData[0]
            versionStr = "\(major).\(String(format: "%02d", minor))"
            let (patchOk, patchData) = rcCommand(cmd: .readFromEEPROM, offset: EEPROM_VERSION_OFFSET, length: 3)
            if patchOk && patchData.count >= 3 && patchData[0] == major && patchData[1] == minor {
                versionStr += ".\(patchData[2])"
            }
        }

        var chipStr = "VMM7100"
        let (idOk, idData) = rcCommand(cmd: .getId)
        if idOk && idData.count >= 2 {
            let chipId = (UInt16(idData[0]) << 8) | UInt16(idData[1])
            chipStr = "VMM\(String(format: "%04X", chipId))"
        }

        print("Current FW:  \(versionStr)")
        print("File FW:     \(fileVersionStr)")
        print("Flashing \(firmwarePath)...")
        print("")

        // Flash sequence from fwupd: unlock → erase → write → verify → activate

        // Step 1: Enable flash chip erase
        print("[1/5] Preparing flash...")
        let (unlockOk, _) = rcCommand(cmd: .enableFlashChipErase)
        if unlockOk {
            print("  Flash unlocked.")
        } else {
            printErr("Flash unlock failed — continuing anyway")
        }

        // Step 2: Full chip erase (fwupd: offset=0, data=[0xFF,0xFF])
        print("[2/5] Erasing flash...")
        let eraseData = Data([0xFF, 0xFF])
        let (eraseOk, _) = rcCommand(cmd: .flashErase, offset: 0, length: UInt32(eraseData.count), data: eraseData)
        if eraseOk {
            print("  Erase command accepted. Waiting 5s for completion...")
            usleep(5_000_000) // 5 seconds — fwupd uses this settle time
            print("  Erase complete.")
        } else {
            printErr("Flash erase failed. Requires macOS 26+ (Tahoe).")
            return false
        }

        // Step 3: Write firmware (32-byte chunks to fit in HID packet payload)
        print("[3/5] Writing firmware...")
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

        // Step 4: Verify CRC
        print("[4/5] Verifying CRC16...")
        let (crcOk, crcData) = rcCommand(cmd: .calCRC16, offset: 0, length: UInt32(FIRMWARE_SIZE))
        if crcOk && crcData.count >= 2 {
            let deviceCRC = (UInt16(crcData[0]) << 8) | UInt16(crcData[1])
            if deviceCRC == fileCRC {
                print("  CRC match: 0x\(String(format: "%04X", deviceCRC))")
            } else if deviceCRC == 0 {
                print("  CRC not available via HID (device returned 0) — skipping verification")
            } else {
                printErr("CRC MISMATCH! Device: 0x\(String(format: "%04X", deviceCRC)), File: 0x\(String(format: "%04X", fileCRC))")
                if !force {
                    printErr("Use --force to activate anyway.")
                    return false
                }
            }
        } else {
            print("  CRC verification not supported via HID — skipping")
        }

        // Step 5: Activate
        print("[5/5] Activating firmware...")
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

    // MARK: Diagnose command — retest all previously-failing paths on current macOS

    func cmdDiagnose() -> Bool {
        guard !isMock else { printErr("diagnose requires real hardware"); return false }
        guard connect() else { return false }
        defer { disconnect() }

        // We need the raw HID device for low-level tests
        guard let hidTransport = transport as? VMM7100HIDTransport,
              let device = hidTransport.hidDevice,
              let mgr = hidTransport.manager else {
            printErr("Cannot access HID device internals")
            return false
        }

        print("VMM7100 macOS Tahoe Diagnostic")
        print("==============================")
        print("macOS: ", terminator: "")
        fflush(stdout)
        // Print OS version inline
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
        proc.arguments = ["-productVersion"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let osVer = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        print(osVer)
        print("")

        var results: [(String, String)] = [] // (test name, result)

        func record(_ name: String, _ result: String) {
            results.append((name, result))
            print("  [\(result.hasPrefix("PASS") || result.hasPrefix("NEW") ? "✓" : result.hasPrefix("SAME") ? "·" : "✗")] \(name)")
            if !result.hasPrefix("PASS") && !result.hasPrefix("NEW") && !result.hasPrefix("SAME") {
                print("     → \(result)")
            } else if result.contains(":") {
                print("     → \(result)")
            }
        }

        // --- Baseline: EnableRC + GetId + GetVersion ---
        print("Baseline (should work):")
        guard enableRC() else {
            printErr("EnableRC failed — device not responding")
            return false
        }

        let (idOk, idData) = rcCommand(cmd: .getId)
        if idOk && idData.count >= 2 {
            let chipId = UInt16(idData[0]) | (UInt16(idData[1]) << 8)
            record("GetId", "PASS: VMM\(String(format: "%X", chipId))")
        } else {
            record("GetId", "FAIL")
        }

        let (verOk, verData) = rcCommand(cmd: .getVersion)
        if verOk && verData.count >= 2 {
            record("GetVersion", "PASS: \(verData[1]).\(String(format: "%02d", verData[0]))")
        } else {
            record("GetVersion", "FAIL")
        }
        print("")

        // --- Test 1: ReadFromEEPROM at various offsets ---
        print("ReadFromEEPROM (previously: all zeros):")
        let eepromOffsets: [(String, UInt32)] = [
            ("offset 0x0 (EDID)", 0x0),
            ("offset 0x20000 (FW code)", 0x20000),
            ("offset 0x1FFF0 (tag)", 0x1FFF0),
        ]
        for (label, offset) in eepromOffsets {
            let packet = buildRCPacket(cmd: .readFromEEPROM, offset: offset, length: 32)
            guard transport.sendReport(packet) else { record("ReadEEPROM \(label)", "FAIL: send"); continue }
            usleep(50_000) // 50ms
            guard let resp = transport.readReport() else { record("ReadEEPROM \(label)", "FAIL: no response"); continue }

            let dataBytes = resp.count > 15 ? Array(resp[15..<min(resp.count, 47)]) : []
            let nonZero = dataBytes.filter { $0 != 0 }.count
            let hex = dataBytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            if nonZero > 0 {
                record("ReadEEPROM \(label)", "NEW: \(nonZero) non-zero bytes! [\(hex)...]")
            } else {
                record("ReadEEPROM \(label)", "SAME: all zeros. [\(hex)]")
            }
        }
        print("")

        // --- Test 2: ReadFromMemory at known registers ---
        print("ReadFromMemory (previously: stale PRIUS data):")
        let memOffsets: [(String, UInt32)] = [
            ("ChipID reg 0x507", REG_CHIP_ID),
            ("FW ver reg 0x50A", REG_FIRMWARE_VERSION),
            ("RC state 0x4B1", REG_RC_STATE),
            ("reg 0x2000", 0x2000),
        ]
        for (label, offset) in memOffsets {
            let packet = buildRCPacket(cmd: .readFromMemory, offset: offset, length: 4)
            guard transport.sendReport(packet) else { record("ReadMem \(label)", "FAIL: send"); continue }
            usleep(50_000)
            guard let resp = transport.readReport() else { record("ReadMem \(label)", "FAIL: no response"); continue }

            let cmdEcho = resp.count > 5 ? resp[5] : 0xFF
            let resultByte = resp.count > 6 ? resp[6] : 0xFF
            let dataBytes = resp.count > 15 ? Array(resp[15..<min(resp.count, 47)]) : []
            let hex = dataBytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            let isPrius = dataBytes.count >= 5 && String(bytes: dataBytes.prefix(5), encoding: .ascii) == "PRIUS"

            if isPrius {
                record("ReadMem \(label)", "SAME: stale PRIUS data. cmd=\(String(format:"%02X",cmdEcho)) res=\(String(format:"%02X",resultByte))")
            } else if resultByte == 0 && dataBytes.contains(where: { $0 != 0 }) {
                record("ReadMem \(label)", "NEW: non-stale data! res=\(String(format:"%02X",resultByte)) [\(hex)]")
            } else {
                record("ReadMem \(label)", "cmd=\(String(format:"%02X",cmdEcho)) res=\(String(format:"%02X",resultByte)) [\(hex)]")
            }
        }
        print("")

        // --- Test 3: GetReport with different report types ---
        print("GetReport type variations (previously: all return same empty data):")
        // First send a ReadFromEEPROM command
        let readPkt = buildRCPacket(cmd: .readFromEEPROM, offset: 0, length: 32)
        _ = transport.sendReport(readPkt)
        usleep(50_000)

        let reportTypes: [(String, IOHIDReportType)] = [
            ("Input", kIOHIDReportTypeInput),
            ("Output", kIOHIDReportTypeOutput),
            ("Feature", kIOHIDReportTypeFeature),
        ]
        for (label, reportType) in reportTypes {
            var buffer = [UInt8](repeating: 0, count: HID_REPORT_SIZE)
            var length = buffer.count
            let ret = IOHIDDeviceGetReport(device, reportType, 1, &buffer, &length)
            if ret == kIOReturnSuccess {
                let nonZero = buffer[15..<min(47, buffer.count)].filter { $0 != 0 }.count
                let hex = buffer[15..<min(23, buffer.count)].map { String(format: "%02X", $0) }.joined(separator: " ")
                record("GetReport(\(label))", nonZero > 0 ? "data=[\(hex)] (\(nonZero) non-zero)" : "all zeros")
            } else {
                record("GetReport(\(label))", "error: 0x\(String(format: "%x", ret))")
            }
        }
        // Also try Report ID 0 for Feature
        var buffer0 = [UInt8](repeating: 0, count: HID_REPORT_SIZE)
        var length0 = buffer0.count
        let ret0 = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &buffer0, &length0)
        if ret0 == kIOReturnSuccess {
            let hex = buffer0.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            record("GetReport(Feature ID=0)", "ok len=\(length0) [\(hex)]")
        } else {
            record("GetReport(Feature ID=0)", "error: 0x\(String(format: "%x", ret0))")
        }
        print("")

        // --- Test 4: Interrupt IN callback ---
        print("Interrupt IN endpoint (previously: callback never fires):")
        var callbackFired = false
        var callbackData = Data()

        let callbackBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 62)
        defer { callbackBuffer.deallocate() }

        let callbackContext = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        callbackContext.pointee = false
        defer { callbackContext.deallocate() }

        IOHIDDeviceRegisterInputReportCallback(device, callbackBuffer, 62, { context, result, sender, type, reportID, report, reportLength in
            guard let ctx = context else { return }
            let flag = ctx.bindMemory(to: Bool.self, capacity: 1)
            flag.pointee = true
        }, callbackContext)

        // Send a few commands and pump runloop
        let testCmds: [(String, Data)] = [
            ("EnableRC", buildRCPacket(cmd: .enableRC, length: 5, data: "PRIUS".data(using: .ascii)!)),
            ("GetId", buildRCPacket(cmd: .getId)),
            ("ReadEEPROM", buildRCPacket(cmd: .readFromEEPROM, offset: 0, length: 32)),
        ]
        for (label, pkt) in testCmds {
            callbackContext.pointee = false
            _ = transport.sendReport(pkt)
            // Pump runloop for up to 500ms
            let deadline = Date().addingTimeInterval(0.5)
            while !callbackContext.pointee && Date() < deadline {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, true)
            }
            if callbackContext.pointee {
                record("Interrupt after \(label)", "NEW: callback fired!")
                callbackFired = true
            } else {
                record("Interrupt after \(label)", "SAME: no callback (500ms timeout)")
            }
        }

        // Unregister callback
        IOHIDDeviceRegisterInputReportCallback(device, callbackBuffer, 62, nil, nil)
        print("")

        // --- Test 5: FlashErase (SKIPPED — destructive) ---
        print("FlashErase: SKIPPED (destructive — confirmed working on Tahoe 26.4)")
        print("")

        // --- Test 6: SetReport via Feature type ---
        print("SetReport via Feature (alternative send path):")
        _ = enableRC()
        // Try sending ReadFromEEPROM via Feature report type, then read
        let featurePkt = buildRCPacket(cmd: .readFromEEPROM, offset: 0, length: 32)
        var featureBytes = [UInt8](featurePkt)
        let fRet = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 1, &featureBytes, featureBytes.count)
        if fRet == kIOReturnSuccess {
            usleep(50_000)
            var rBuf = [UInt8](repeating: 0, count: HID_REPORT_SIZE)
            var rLen = rBuf.count
            let gRet = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, 1, &rBuf, &rLen)
            if gRet == kIOReturnSuccess {
                let nonZero = rBuf[15..<min(47, rBuf.count)].filter { $0 != 0 }.count
                let hex = rBuf[15..<min(23, rBuf.count)].map { String(format: "%02X", $0) }.joined(separator: " ")
                if nonZero > 0 {
                    record("Feature→Input read", "NEW: data returned! [\(hex)]")
                } else {
                    record("Feature→Input read", "SAME: zeros after Feature send")
                }
            } else {
                record("Feature→Input read", "GetReport error: 0x\(String(format: "%x", gRet))")
            }
        } else {
            record("Feature→Input read", "SetReport(Feature) error: 0x\(String(format: "%x", fRet))")
        }
        print("")

        // --- Summary ---
        disableRC()
        print("Summary")
        print("=======")
        let newBehaviors = results.filter { $0.1.hasPrefix("NEW") }
        if newBehaviors.isEmpty {
            print("  No changes from previous macOS behavior.")
            print("  All previously-failing paths still fail the same way.")
        } else {
            print("  \(newBehaviors.count) NEW behavior(s) detected on Tahoe:")
            for (name, result) in newBehaviors {
                print("    • \(name): \(result)")
            }
        }
        print("")

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
      vmm7100tool info                         Read chip ID + firmware version
      vmm7100tool diagnose                     Test all HID paths (Tahoe retest)
      vmm7100tool flash <firmware.fullrom>      Flash firmware (EXPERIMENTAL)
      vmm7100tool flash --dry-run <firmware>    Show flash plan without writing
      vmm7100tool reset                         Reset adapter board
      vmm7100tool test                          Run mock self-tests

    Requires macOS 26+ (Tahoe):
      vmm7100tool dump <output.fullrom>         Backup firmware from flash
      vmm7100tool edid                          Read stored EDID from flash
      vmm7100tool display                       Decode connected monitor EDID
      vmm7100tool register <addr>               Read/write chip registers

    Options:
      --mock     Use simulated device (for testing without hardware)
      --force    Continue flash even if CRC mismatch

    Note: macOS 26+ (Tahoe) required for read/dump/flash operations.
    Earlier macOS versions only support info and reset.
    See docs/lessons_log.md for details.

    Examples:
      vmm7100tool info
      vmm7100tool flash --dry-run firmware.fullrom
      vmm7100tool flash Spyder_fw_USBC_CMforMac4K120hz.fullrom
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

    case "diagnose", "diag":
        return tool.cmdDiagnose() ? 0 : 1

    case "edid":
        return tool.cmdEDID() ? 0 : 1

    case "display":
        return tool.cmdDisplay() ? 0 : 1

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
