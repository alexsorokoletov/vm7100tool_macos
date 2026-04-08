# VMM7100 macOS HID Protocol — Findings & Lessons

## Device Overview

- Synaptics VMM7100 "Spyder" USB-C to HDMI 2.1 converter
- VID `0x06CB`, PID `0x7100`
- USB 2.0 High Speed (480 Mbps)
- HID interface: vendor usage page `0xFF00`, Report ID 1, 61-byte payload (62 with ID)
- 1 interrupt IN endpoint, `bMaxPacketSize0 = 64`, `ReportInterval = 64ms`
- `MaxOutputReportSize = 62`, `MaxInputReportSize = 62`, `MaxFeatureReportSize = 1` (per macOS ioreg)

## What Works

### IOHIDManager with seize (the correct macOS approach)
- `IOHIDManagerOpen` with `kIOHIDOptionsTypeSeizeDevice` — takes device from AppleUserHIDDrivers
- `IOHIDDeviceSetReport` (Output, Report ID 1) — sends commands
- `IOHIDDeviceGetReport` (Input, Report ID 1) — reads command acknowledgment

### Working RC commands via HID
| Command | Code | Result |
|---------|------|--------|
| EnableRC | `0x01` with "PRIUS" data | Works, byte[4]=1 confirms enabled |
| DisableRC | `0x02` | Works |
| GetId | `0x03` | Returns chip ID at bytes[15-16] (LE): `00 71` = VMM7100 |
| GetVersion | `0x04` | Returns version at bytes[15-16]: minor, major. FW 7.02 confirmed |

### HID packet format (send)
```
[0]    Report ID (0x01)
[1]    0x00
[2]    Payload length indicator (0x11 for EnableRC, varies)
[3-4]  0x00, 0x00
[5]    RC_CMD | 0x80 (execute bit)
[6]    0x00
[7-10] Offset (4 bytes LE)
[11-14] Length (4 bytes LE)
[15+]  Data (up to 47 bytes)
```

### HID response format (verified from real device)
```
[0]    0x01 Report ID
[1]    0x00
[2]    0x2C (payload length, always 44)
[3]    0x00
[4]    RC enabled state (0x01=enabled, 0x00=disabled)
[5]    Command echo (without execute bit = complete)
[6]    Varies (not a reliable result code)
[7-10] Offset echo (LE)
[11-14] Length echo (LE) — sometimes 0 even when data present
[15+]  Response data (only 2-3 meaningful bytes, rest is stale buffer)
[47]   Varies per command (possibly checksum or counter)
```

### Version byte order
- GetVersion returns `[minor, major]` at bytes 15-16
- Real device: `02 07` = version 7.02
- Third byte unreliable — contains stale data from prior command buffer

### Chip ID byte order
- GetId returns chip ID little-endian at bytes 15-16
- Real device: `00 71` = 0x7100

## What Does NOT Work (Reads)

### ReadFromEEPROM (cmd `0x30`) — FAILS
- Command is acknowledged (byte[5] echoes `0x30`, no error)
- Data bytes [15+] are always **all zeros**
- Tested at offsets: 0x0, 0x80, 0x100, 0x1FFF0, 0x20000, 0x40000
- Firmware file has real data at these offsets (EDID at 0x0, code at 0x20000)
- Conclusion: device doesn't populate HID report buffer with EEPROM data

### ReadFromMemory (cmd `0x31`) — FAILS
- Command acknowledged but data bytes contain **stale data from previous command**
- byte[6] = 0x01 (possibly error indicator for this command)
- Tested at registers: 0x000, 0x507, 0x50A, 0x170E, 0x2000, 0x022C
- All return identical stale bytes (e.g., "PRIUS" remnants)

### FlashMapping (cmd `0x07`) — FAILS
- byte[6] = 0x01, stale data only

## What We Tried (All Failed for Reads)

### 1. Different HID report types for GetReport
```swift
IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, 1, ...)    // zeros
IOHIDDeviceGetReport(dev, kIOHIDReportTypeOutput, 1, ...)   // zeros
IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, ...)  // zeros
```
All three return the same empty data for ReadFromEEPROM.

### 2. Feature reports for sending (Report ID 0)
```swift
IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0, ...)  // succeeds
IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 1, ...)  // succeeds
```
EnableRC works via Feature reports (both ID 0 and 1), but subsequent reads still return empty.

### 3. Interrupt IN endpoint via IOHIDDeviceRegisterInputReportCallback
```swift
IOHIDDeviceRegisterInputReportCallback(dev, buffer, 62, callback, nil)
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), ...)
// ... send command, pump runloop ...
```
Callback **never fires**. No interrupt reports received for any command. Tested with:
- SetReport Output (Report ID 1) → no interrupt
- SetReport Feature (Report ID 0) → no interrupt
- Various delays (10ms to 2000ms) → no interrupt

### 4. Multiple sequential GetReport reads after send
Sent ReadFromEEPROM, then called GetReport 3 times with increasing delays (50ms, 100ms, 200ms). All returned identical empty data.

### 5. Longer delays
Tested up to 500ms between send and read. No difference.

### 6. byte[2] payload length variations
vmm7100reset.swift uses byte[2]=0x11 for EnableRC and 0x0C for other packets. Tried matching these values for read commands — no effect on data return.

### 7. Raw IOKit USB interface (bypassing IOHIDManager)
```swift
IOUSBInterfaceInterface.USBInterfaceOpen() → kIOReturnExclusiveAccess
```
macOS AppleUserHIDDrivers holds exclusive access. Cannot open raw USB interface even with device unplugged from display.

## Why Reads Fail — Root Cause Analysis

### Windows tool architecture (from binary analysis)
AtUsbHid.dll exports reveal the Windows communication pattern:
- **Send**: `HidD_SetFeature` → USB SET_REPORT Feature (control transfer)
- **Read**: `ReadFile` on HID file handle → reads from **interrupt IN endpoint**
- Key: `readContinuous` and `readData` both use `ReadFile`, NOT `HidD_GetFeature`

### The gap on macOS
- macOS `IOHIDDeviceGetReport` → USB GET_REPORT (control transfer) — only returns last report state
- macOS interrupt callback → should receive async reports, but VMM7100 never sends them in our testing
- Possible causes:
  1. Device requires specific initialization to enable interrupt reporting (unknown handshake)
  2. macOS HID driver doesn't poll the interrupt endpoint for this vendor-specific device
  3. The VMM7100 firmware only sends interrupt reports in response to DP AUX-triggered events

### 8. Raw USB pipe read after releasing HIDManager
```swift
IOHIDManagerClose(mgr, 0)       // release HID driver
usleep(500000)                   // wait for driver release
IOUSBInterfaceInterface.USBInterfaceOpen() → kIOReturnExclusiveAccess
```
macOS re-claims the HID interface immediately. Cannot access raw interrupt IN pipe.

### 9. IOHIDDeviceRegisterInputReportCallback with instance-stored buffer
```swift
class HIDReader {
    var reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 62)  // kept alive
    // ...register callback with Unmanaged<Self> context...
    // ...pump CFRunLoop after each send...
}
```
Agent research suggested this pattern (matching hidapi library approach). **Callback still never fires.** macOS HID driver doesn't poll the interrupt IN endpoint for this vendor-specific device class.

### What would be needed
- **DriverKit extension** with direct interrupt IN pipe access (bypasses HID driver)
- Or **USB packet capture** from Windows to discover any initialization handshake that enables interrupt reporting
- Or accept that reads aren't available via macOS HID and focus on write path (flash)

## Firmware File Format (.fullrom)

From examining `Spyder_fw_USBC_CMforMac4K120hz.fullrom` (1,048,576 bytes):
```
0x00000 - 0x0007F:  EDID block (128 bytes, starts with 00 FF FF FF FF FF FF 00)
0x00080 - 0x1FFFF:  Zeros (padding)
0x20000 - 0xFFFFF:  Firmware code (EEPROM_BANK_OFFSET from fwupd)
```

## Flash Write Findings

### Write commands "succeed" but don't persist
- `WriteToEEPROM` (cmd 0x20) returns byte[6]=0 (success) at offsets 0x0 and 0x20000
- Returns byte[6]=1 (invalid) at offset 0xF0000
- But GetVersion unchanged after writing full firmware → data not actually written to flash
- SPI NOR flash requires erase before write — without erase, writes are no-ops

### FlashErase always fails via HID
All parameter variations tried:

| Attempt | Params | Result |
|---------|--------|--------|
| Sector erase | offset=0xF0000, len=0x3000 | byte[6]=3 (failed) |
| Sector erase | offset=0x0, len=0x3000 | byte[6]=3 |
| 4K erase | offset=0x0, len=0x1000 | byte[6]=3 |
| Raw 64K | offset=0x0, len=0x10000 | byte[6]=3 |
| fwupd format | offset=0, data=[0xFF,0xFF], len=2 | byte[6]=3 |
| Alt: offset as type | offset=0xFFFF, len=0 | byte[6]=3 |
| After EnableFlashChipErase (0x08) | all above | still byte[6]=3 |

### Correct flash parameters (from fwupd source)
fwupd's `set_flash_sector_erase` for Spyder/Cayenne full chip erase:
```c
// buf = uint16_le(0xFFFF + 0) = [0xFF, 0xFF]
rc_set_command(FLASH_ERASE, offset=0, data=buf, len=2)
```
Then sleep 5000ms, then write 64-byte chunks, verify CRC16, activate.

### Firmware size is 320KB, not 1MB
- `.fullrom` files are 1MB but actual firmware = `CAYENNE_FIRMWARE_SIZE = 0x50000` (320KB)
- Layout: EDID at 0x0, zeros 0x80-0x1FFFF, firmware code at 0x20000-0x6FFFF

### ActivateFirmware returns unknown code
- `ActivateFirmware` (cmd 0x18) returns byte[6]=5, which is outside documented range (0-4)
- Possibly means "no new firmware detected" or "flash unchanged"

### Restart sequence (from vmm7100reset + fwupd)
fwupd's restart after flash:
```
WriteToMemory(offset=0x2020021C, data=[0xF5, 0x00, 0x00, 0x00])
```
This matches vmm7100reset.swift's third packet exactly.

## Conclusion: Why HID Flash Doesn't Work

**FlashErase is not supported via HID.** The VMM7100's HID firmware accepts the command but returns error 3 (failed) for all parameter variations. Without erase, SPI NOR writes are no-ops.

The HID interface supports:
- ✅ EnableRC / DisableRC
- ✅ GetId, GetVersion (read chip info from registers)
- ✅ WriteToMemory (for reset/restart sequence)
- ❌ FlashErase (always fails)
- ❌ ReadFromEEPROM / ReadFromMemory (returns empty/stale)
- ⚠️ WriteToEEPROM (acknowledged but no effect without prior erase)
- ⚠️ ActivateFirmware (returns code 5)
- ⚠️ CalCRC16 (returns zeros)

VmmHIDTool on Windows likely works because Windows can simultaneously access the DP AUX channel through the GPU driver (AMD/Intel display driver) alongside HID. The "HID" in VmmHIDTool may be misleading — it probably uses HID for control/status but DP AUX for actual flash operations.

### Only viable paths for macOS firmware flash
1. **USB packet capture** from VmmHIDTool on Windows (Wireshark + USBPcap) to discover if there's a secret initialization sequence
2. **Windows VM** with USB passthrough (UTM/Parallels) — the documented working approach
3. **DP AUX on macOS** — requires access to DisplayPort AUX channel, see section below

## DP AUX on macOS

### What is DP AUX?
DisplayPort Auxiliary (AUX) channel is a low-bandwidth sideband channel in DisplayPort connections. It's used for:
- DPCD (DisplayPort Configuration Data) register access
- EDID reading
- Link training
- MST (Multi-Stream Transport) sideband messaging
- **Firmware updates** (Flash-over-AUX)

### How Linux exposes DP AUX
Linux kernel (4.6+) exposes `/dev/drm_dp_aux*` devices. fwupd reads/writes DPCD registers directly:
```c
fu_dpaux_device_read(device, 0x4B2, buf, 1, timeout, error)  // read RC_CMD register
fu_dpaux_device_write(device, 0x4C0, data, 32, timeout, error)  // write RC_DATA
```

### macOS DP AUX status
- **No public API.** macOS does not expose DP AUX channel to userspace.
- GPU drivers (Apple Silicon GPU, AMD) handle DP AUX internally for link training and EDID.
- `IOFramebuffer` / `IODisplay` kexts manage display connections but don't expose raw AUX access.
- No equivalent to Linux's `/dev/drm_dp_aux*`.

### Potential macOS DP AUX approaches (all speculative)

1. **IOKit IOFramebuffer private API**
   - `IOFramebuffer` has internal DP AUX methods used by macOS for EDID/DPCD
   - These are private, undocumented, and change between macOS versions
   - Would require reverse engineering the IOFramebuffer kernel extension

2. **DriverKit / DEXT**
   - A custom DriverKit extension could potentially access the USB device's DP AUX
   - But DP AUX goes through the GPU, not USB — the USB-C port routes DP signals to the GPU
   - DriverKit doesn't have APIs for GPU/display subsystem access

3. **IODisplayConnect / IODisplay**
   - `IODisplayConnect` objects in IORegistry contain EDID data read via AUX
   - But there's no public method to send arbitrary DPCD register writes

4. **Metal / CoreDisplay private frameworks**
   - `CoreDisplay.framework` has private SPI for display management
   - `CGSDisplayAuxIO` or similar private functions may exist but are undocumented

5. **I2C-over-USB fallback**
   - The VMM7100 has an I2C debug port (from datasheet strings)
   - If accessible via USB, could bypass the DP AUX requirement
   - But no evidence the HID interface exposes I2C

### Bottom line
macOS DP AUX access requires either:
- Apple adding a public API (unlikely for niche use case)
- Reverse engineering private IOFramebuffer internals (fragile, breaks on updates)
- A kernel extension or DriverKit driver for raw DPCD access (significant effort)

For now, **Windows VM with USB passthrough remains the practical solution** for firmware flashing.

## Key Sources

- [vmm7100reset.swift](https://github.com/waydabber/vmm7100reset) — working macOS HID send pattern, reset packet bytes
- [fwupd synaptics-mst](https://github.com/fwupd/fwupd/tree/main/plugins/synaptics-mst) — RC command protocol, register map (via DP AUX, not HID)
- [fwupd fu-synaptics-mst.rs](https://github.com/fwupd/fwupd/blob/main/plugins/synaptics-mst/fu-synaptics-mst.rs) — command enum values, register addresses
- [VmmDPTool passwords gist](https://gist.github.com/mkem114/d685ff9c7368392c07e9118ab46609f7) — advanced password format: `Synab1f1@SJ[MMDD]`
- [Cable Matters KB article](https://kb.cablematters.com/index.php?View=entry&EntryID=147) — firmware update instructions
- AtUsbHid.dll disassembly — confirmed `HidD_SetFeature` + `ReadFile` pattern
