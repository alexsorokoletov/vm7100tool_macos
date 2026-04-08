# vmm7100tool

Native macOS CLI tool for Synaptics VMM7100 USB-C to HDMI 2.1 adapters. Flash firmware, read device info, dump/restore, reset board — no Windows or VM required.

## Build

```bash
swiftc vmm7100tool.swift -o vmm7100tool
```

## Usage

```bash
# Read adapter info (FW version, chip ID)
./vmm7100tool info

# Backup current firmware
./vmm7100tool dump backup.fullrom

# Flash new firmware (auto-backs up current FW first)
./vmm7100tool flash Spyder_fw_USBC_CMforMac4K120hz.fullrom

# Preview flash plan without writing
./vmm7100tool flash --dry-run firmware.fullrom

# Reset adapter board
./vmm7100tool reset

# Read EDID from connected display
./vmm7100tool edid

# Read/write chip registers
./vmm7100tool register 0x507
./vmm7100tool register 0x507 0x01

# Run self-tests (no hardware needed)
./vmm7100tool test
```

## How it works

The VMM7100 chip exposes a USB HID interface (VID `0x06CB`, PID `0x7100`) with vendor-specific reports. The tool sends RC (Remote Control) commands via HID SET_REPORT/GET_REPORT to read chip info, erase flash, write firmware, and verify CRC.

No DP Alt Mode required — communication happens over USB data pins, not DisplayPort AUX channel.

## Safety

- `flash` always creates an auto-backup of current firmware before writing (timestamped with device info)
- `--dry-run` lets you preview the flash plan
- CRC16 verification after write
- `--force` to continue past CRC mismatch (use with caution)

## Sources & References

- [vmm7100reset.swift](https://github.com/waydabber/vmm7100reset) — macOS IOKit USB HID communication pattern for VMM7100
- [fwupd synaptics-mst plugin](https://github.com/fwupd/fwupd/tree/main/plugins/synaptics-mst) — RC command protocol, register map, flash sequence
- [VmmDPTool passwords & reverse engineering](https://gist.github.com/mkem114/d685ff9c7368392c07e9118ab46609f7) — Synaptics tool internals
- [Cable Matters firmware update KB](https://kb.cablematters.com/index.php?View=entry&EntryID=147) — Windows firmware update instructions
- [VMM7100 firmware upgrade PDF](How%20to%20upgrade%20firmware%20for%20the%20VMM7100%20adapter.pdf) — Original Windows flashing guide
- [MacRumors 4K120Hz thread](https://forums.macrumors.com/threads/dp-usb-c-thunderbolt-to-hdmi-2-1-4k-120hz-rgb4-4-4-10b-hdr-with-apple-silicon-m1-m4-now-possible.2381664/) — Community discussion on VMM7100 firmware modding

## Status

- Mock tests: 23/23 passing
- Real device testing: pending (protocol packet format may need adjustment based on actual device responses)

## License

MIT
