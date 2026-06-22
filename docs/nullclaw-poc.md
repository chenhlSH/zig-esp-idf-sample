# NullClaw ESP32 PoC

A minimal proof-of-concept demonstrating the [NullClaw](https://github.com/nullclaw/nullclaw) architecture running on an ESP32-S3 microcontroller.

> **Null overhead. Null compromise. Now on bare metal.**

## Overview

This example brings the NullClaw agent runtime to a $5 ESP32-S3 board. It implements a UART-based REPL that communicates with any OpenAI-compatible LLM provider over HTTPS, executes hardware tool calls (GPIO, UART, SPI, I2C), and returns results — all on a device with 267 KB of usable RAM.

```
┌─────────────┐    HTTPS/TLS    ┌─────────────────┐
│  ESP32-S3   │ ──────────────▶ │  LLM Provider   │
│  (NullClaw  │ ◀────────────── │  (DeepSeek,     │
│   PoC)      │    JSON resp    │   OpenAI, etc.) │
└──────┬──────┘                 └─────────────────┘
       │
       │ UART REPL (115200 baud)
       ▼
┌─────────────┐
│  idf.py     │
│  monitor    │
└─────────────┘
```

## Architecture

The PoC mirrors the NullClaw source layout:

| NullClaw Module | ESP32 PoC Equivalent | Description |
|---|---|---|
| `channels/interactive.zig` | `uartReadLine()` / `uartWriteLn()` | UART serial REPL via `idf.py monitor` |
| `providers/openai.zig` | `callLLM()` | OpenAI-compatible HTTP provider with TLS |
| `tools/gpio.zig` | `execGpioSet()` | GPIO pin control (level 0/1) |
| `tools/file_write.zig` | `execFileCreate()` | File creation via NVS key/value store |
| `tools/uart.zig` | `execUartTx()` | Bit-bang software UART TX on any GPIO |
| `tools/spi.zig` | `execSpiTransfer()` | Bit-bang SPI Mode 0 transfer |
| `tools/i2c.zig` | `execI2cScan/Write/Read()` | Bit-bang I2C with bus scanning |
| `agent.zig` | `agentTurn()` | ReAct tool-calling loop (max 3 rounds) |
| — | `proto_engine.c` | C-level protocol engine with FreeRTOS task pool |

## Tools

The agent has access to 7 tools:

| Tool | Description | Key Parameters |
|---|---|---|
| `gpio_set` | Set a GPIO pin high or low | `pin` (0–48), `level` (0/1) |
| `file_create` | Store content in NVS | `path`, `content` |
| `uart_tx` | Send bytes via software UART | `pin`, `baud` (300–115200), `data` (hex) |
| `spi_transfer` | SPI Mode 0 full-duplex transfer | `clk`, `mosi`, `miso`, `cs`, `data` (hex), `clock_hz` |
| `i2c_scan` | Scan I2C bus for devices (0x03–0x77) | `sda`, `scl` |
| `i2c_write` | Write bytes to an I2C device | `sda`, `scl`, `addr`, `data` (hex) |
| `i2c_read` | Read bytes from an I2C device | `sda`, `scl`, `addr`, `len` |

### GPIO Pin Constraints (ESP32-S3)

- **Output-capable:** 0–21, 35–48
- **Input-only:** 22–34 (cannot be used for bit-bang protocols)
- **Avoid:** 0, 1, 3, 44, 45 (strapping / console UART pins)

The agent validates GPIO pins before execution and will suggest alternatives for invalid pins.

### Protocol Engine

All bit-bang protocols run in a C-level engine (`main/proto_engine.c`) with:

- **Precise timing** via `esp_rom_delay_us()` (cycle-accurate on ESP32-S3)
- **FreeRTOS task pool** — max 3 concurrent protocol operations via counting semaphore
- **Automatic GPIO direction** — pins are configured as input/output as needed

## Build & Flash

### Prerequisites

- ESP-IDF 6.0 (or compatible 5.x)
- ESP32-S3 development board
- USB-C or USB-UART connection

### Steps

```bash
# 1. Source ESP-IDF environment
source ~/esp/esp-idf/export.sh

# 2. Build the nullclaw-poc example
idf.py -DCONFIG_ZIG_EXAMPLE_NULLCLAW_POC=y build

# 3. Flash and monitor
idf.py -p /dev/ttyACM0 flash monitor
```

### Configuration

Configure via `idf.py menuconfig`:

| Menu Path | Config Key | Description |
|---|---|---|
| NullClaw PoC → LLM API URL | `CONFIG_NULLCLAW_LLM_API_URL` | LLM endpoint (e.g. `https://api.deepseek.com/v1/chat/completions`) |
| NullClaw PoC → LLM API Key | `CONFIG_NULLCLAW_LLM_API_KEY` | Bearer token for authentication |
| NullClaw PoC → LLM Model | `CONFIG_NULLCLAW_LLM_MODEL` | Model identifier (e.g. `deepseek-v4-flash`) |
| Example → WiFi SSID | `CONFIG_ESP_WIFI_SSID` | WiFi network name |
| Example → WiFi Password | `CONFIG_ESP_WIFI_PASSWORD` | WiFi password |

Or edit `sdkconfig` directly:

```
CONFIG_NULLCLAW_LLM_API_URL="https://api.deepseek.com/v1/chat/completions"
CONFIG_NULLCLAW_LLM_API_KEY="sk-your-key-here"
CONFIG_NULLCLAW_LLM_MODEL="deepseek-v4-flash"
CONFIG_ESP_WIFI_SSID="your-wifi"
CONFIG_ESP_WIFI_PASSWORD="your-password"
```

## Example Session

```
+------------------------------------------+
|     NullClaw ESP32 PoC  --  Ready!       |
|  AI agent with GPIO + file tools         |
|  Type a message, or 'quit' to exit.      |
+------------------------------------------+

> set gpio 2 high and gpio 7 low
[llm] Requesting deepseek-v4-flash...
[llm] content-length: 1097
[llm] Read 1097 bytes
[agent] Tool: gpio_set
[tool] GPIO 2 -> 1
[agent] Tool: gpio_set
[tool] GPIO 7 -> 0
[llm] Read 859 bytes
Done! GPIO 2 is now HIGH, GPIO 7 is now LOW.
>

> scan i2c on sda=21 scl=4
[agent] Tool: i2c_scan
[scan] Found devices at: 0x3c 0x68
I found 2 I2C devices on the bus:
- 0x3C (common SSD1306 OLED display)
- 0x68 (common DS3231 RTC or MPU6050 IMU)
>

> send "hello" via uart on pin 18 at 9600 baud
[agent] Tool: uart_tx
[tool] UART TX pin=18 baud=9600 len=5
Sent "hello" (5 bytes) on GPIO 18 at 9600 baud.
>
```

## Implementation Notes

### Memory Management

- **Static buffers:** 16 KB response buffer, 4 KB request buffer — no stack allocation
- **Per-iteration arena:** JSON parsing and tool execution use a fresh `ArenaAllocator` each round, freed immediately after — prevents OOM across 3 tool-calling rounds
- **No dynamic HTTP response:** `callLLM()` returns a direct slice of the static buffer, not a heap copy

### TLS & Time

- TLS uses `crt_bundle_attach` for certificate validation
- NTP time sync runs at startup (`sync_time()`) — required for certificate date validation
- WiFi power-save is disabled (`WIFI_PS_NONE`) to reduce peak current draw

### Error Handling

- HTTP errors print the ESP-IDF error string via `esp_err_to_name()`
- Tool execution errors are returned to the LLM as text (the model can retry or explain)
- JSON parse errors dump the first 200 bytes of raw response for debugging
- Network timeouts are set to 10 seconds to prevent indefinite hangs

### Limitations

- **No streaming:** Responses are buffered fully before parsing (16 KB limit)
- **No multi-turn memory:** Each `agentTurn` is independent; the conversation context is only the current user input + tool results within 3 rounds
- **NVS-only storage:** `file_create` stores to NVS with 15-char key truncation — no POSIX filesystem
- **No WiFi reconnection:** If WiFi drops, the device does not automatically reconnect
- **Bit-bang protocols:** Software UART/SPI/I2C have timing limitations compared to hardware peripherals

## File Structure

```
main/
├── examples/
│   └── nullclaw-poc.zig     # Main PoC: REPL, agent loop, tool dispatch
├── wifi_default_config.c    # C shims: WiFi init, UART init, NTP sync
├── proto_engine.c           # C protocol engine: bit-bang UART/SPI/I2C
└── CMakeLists.txt           # Component wiring and dependency declarations
```

## Acknowledgments

This example is part of the [zig-esp-idf-sample](https://github.com/kassane/zig-esp-idf-sample) project, a fork of [kassane/zig-esp-idf-sample](https://github.com/kassane/zig-esp-idf-sample) by [kassane](https://github.com/kassane).

The NullClaw architecture and agent design are from [nullclaw/nullclaw](https://github.com/nullclaw/nullclaw) — the smallest fully autonomous AI assistant infrastructure, written in Zig.

The protocol engine uses ESP-IDF's `esp_rom_delay_us()` for cycle-accurate bit-banging on ESP32-S3.
