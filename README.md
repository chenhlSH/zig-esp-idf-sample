# Zig + ESP-IDF Sample Project

This repository is a fork of [kassane/zig-esp-idf-sample](https://github.com/kassane/zig-esp-idf-sample). It keeps the upstream Apache-2.0 / MIT-0 license model and updates the README to match what is actually in this tree.

## Status

Experimental. The project is a sample integration layer for building Zig code inside an ESP-IDF application, not a drop-in replacement for the ESP-IDF C/C++ toolchain.

## What This Repo Contains

- A Zig entry point in [main/app.zig](main/app.zig)
- Reusable Zig wrappers in [imports/](imports)
- Example firmware modules in [main/examples/](main/examples)
- ESP-IDF component wiring in [main/CMakeLists.txt](main/CMakeLists.txt)
- C/C++ shims used by the ESP-IDF component in [main/](main)

## Actual Runtime Shape

The default build uses [main/app.zig](main/app.zig). Example selection is handled in [main/CMakeLists.txt](main/CMakeLists.txt) through Kconfig switches, and the selected Zig file is passed to `build.zig` with `-Dexample=...`.

Current example files include:

- `smartled-rgb.zig`
- `wifi-station.zig`
- `dsp-math.zig`
- `gpio-blink.zig`
- `http-server.zig`
- `ble-gatt-server.zig`
- `i2c-scan.zig`
- `uart-echo.zig`
- `matter-light.zig`
- `nullclaw-poc.zig`

### Example: nullclaw-poc.zig

Detailed PoC demonstrating an embedded AI agent that can call tools (GPIO control and file creation) via an OpenAI-compatible provider.

- Purpose: a small proof-of-concept that shows a REPL-driven agent running on the ESP32 which can:
	- Send prompts to an LLM provider over HTTPS and parse responses.
	- Execute declared "tool" functions returned by the LLM (e.g. `gpio_set`, `file_create`).
	- Echo content responses back to the UART console.

- Location: [main/examples/nullclaw-poc.zig](main/examples/nullclaw-poc.zig)

- Architecture / components (mirrors the in-repo layout):
	- Channel: UART REPL handled via console wrappers.
	- Provider: OpenAI-compatible HTTP LLM calls (`callLLM` in the example).
	- Tools: `gpio_set` (control GPIO pins) and `file_create` (stores content in NVS as a simple file backing store).
	- Agent loop: a ReAct-like loop that parses JSON responses, executes tool calls, and injects tool results back into the conversation for up to 3 rounds.

- How it works (high level):
	1. The REPL reads a user line from UART.
	2. The agent sends a JSON request to the configured LLM endpoint (model, system prompt and a `tools` schema are included).
	3. If the model's response contains `tool_calls`, the example executes each tool and appends the result to the prompt, repeating up to 3 rounds; otherwise it prints the `content` string to UART.

- Build & run:
	- Configure options with `idf.py menuconfig` (see configuration items below).
	- Build the example with:

```bash
idf.py -DCONFIG_ZIG_EXAMPLE_NULLCLAW_POC=y build
idf.py -DCONFIG_ZIG_EXAMPLE_NULLCLAW_POC=y flash
```

- Configuration (Kconfig items referenced in the source):
	- `CONFIG_NULLCLAW_LLM_API_URL` — LLM HTTP endpoint URL
	- `CONFIG_NULLCLAW_LLM_API_KEY` — API key / bearer token
	- `CONFIG_NULLCLAW_LLM_MODEL` — model identifier used in the request JSON
	- Standard WiFi config: `CONFIG_ESP_WIFI_SSID`, `CONFIG_ESP_WIFI_PASSWORD`

- Important implementation notes & limitations:
	- The example uses fixed-size static buffers (16KiB response buffer, 4KiB request buffer) to avoid dynamic allocations on the stack.
	- `file_create` stores content into NVS (key truncated to 15 chars) — there is no POSIX filesystem example here; the project uses NVS as a tiny key/value "file" backend.
	- Console I/O relies on C shim functions in `main/` such as `init_console_uart()` and `console_getchar()`.
	- TLS certificate validation requires the clock to be synchronized (`sync_time()` is called at startup).
	- The LLM response parsing is minimal — the PoC expects a JSON structure with `choices[0].message` and supports `tool_calls` arrays as produced by the example provider format.

If you want, I can also add a short troubleshooting subsection (common errors, how to inspect NVS entries, and example LLM prompts that trigger tool calls). 
## Prerequisites

- Zig 0.16.0 or a compatible build
- ESP-IDF 5.0 or 6.0
- A target supported by the current Zig/ESP-IDF combination

## Targets

The current build logic in [build.zig](build.zig) is aimed at these ESP32 families:

- ESP32
- ESP32-S2
- ESP32-S3
- ESP32-C2
- ESP32-C3
- ESP32-C5
- ESP32-C6
- ESP32-C61
- ESP32-H2
- ESP32-H21
- ESP32-H4
- ESP32-P4

RISC-V targets can work with upstream Zig using generic CPU fallbacks. Xtensa targets still require an Espressif-compatible Zig toolchain.

## Notes

- The allocator examples in the code are intentionally small and use ESP-IDF heap wrappers, not custom filesystem abstractions.
- The older README mentioned file systems more broadly than this repository currently demonstrates directly, so that wording has been removed here.

## License

This fork keeps the upstream dual-license setup:

- [Apache-2.0](LICENSE-APACHE)
- [MIT-0](LICENSE-MIT)

Please preserve the original license notices when redistributing or reusing this code.