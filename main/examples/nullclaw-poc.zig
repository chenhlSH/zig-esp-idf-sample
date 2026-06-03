// ═══════════════════════════════════════════════════════════════════════════════
// NullClaw ESP32 PoC — Embedded AI Agent with Tool Calling
// ═══════════════════════════════════════════════════════════════════════════════
//
// A minimal proof-of-concept demonstrating the nullclaw architecture on ESP32-S3.
//
// Architecture (mirrors nullclaw/src/):
//   Channel  → channels/interactive.zig  — UART serial REPL (idf.py monitor)
//   Provider → providers/openai.zig      — OpenAI-compatible LLM via HTTP
//   Tools    → tools/gpio.zig            — GPIO pin control
//              tools/file_write.zig      — File creation via VFS
//   Agent    → agent.zig                 — ReAct tool-calling loop
//
// Build:
//   idf.py -DCONFIG_ZIG_EXAMPLE_NULLCLAW_POC=y build
//
// Configure (before build):
//   idf.py menuconfig → NullClaw PoC Configuration
//     - LLM API URL, API Key, Model
//   idf.py menuconfig → Example Configuration
//     - WiFi SSID, WiFi Password

const std = @import("std");
const builtin = @import("builtin");
const idf = @import("esp_idf");
const sys = idf.sys;

// ─── Console I/O via esp_rom_printf (works with ESP-IDF console, no driver)
// ─── C wrappers (defined in wifi_default_config.c)
extern fn wifi_get_default_config(out: *sys.wifi_init_config_t) void;
extern fn init_console_uart() void;
extern fn sync_time() void;
extern fn console_getchar() c_int;

// ─── Protocol engine (defined in proto_engine.c)
extern fn proto_init() void;
extern fn proto_uart_tx_sync(tx_pin: c_int, baud: c_int, data: [*c]const u8, len: c_int) c_int;
extern fn proto_spi_transfer_sync(clk: c_int, mosi: c_int, miso: c_int, cs: c_int, tx: [*c]const u8, rx: [*c]u8, len: c_int, hz: c_int) c_int;
extern fn proto_i2c_write_sync(sda: c_int, scl: c_int, addr: u8, data: [*c]const u8, len: c_int) c_int;
extern fn proto_i2c_read_sync(sda: c_int, scl: c_int, addr: u8, data: [*c]u8, len: c_int) c_int;
extern fn proto_i2c_scan(sda: c_int, scl: c_int) u32;

fn uartWrite(s: []const u8) void {
    // esp_rom_printf needs a null-terminated string, use a temp buffer
    var buf: [512]u8 = undefined;
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    _ = sys.esp_rom_printf("%s", @as([*c]const u8, @ptrCast(&buf)));
}

fn uartWriteLn(s: []const u8) void {
    uartWrite(s);
    _ = sys.esp_rom_printf("\r\n");
}

fn uartReadLine(buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (i < buf.len - 1) {
        const ch = console_getchar();
        if (ch < 0) continue; // -1 means no data, yielded to idle task
        const c: u8 = @intCast(ch);
        if (c == '\n' or c == '\r') {
            if (i > 0) {
                _ = sys.esp_rom_printf("\r\n");
                break;
            }
            continue;
        }
        // Handle backspace/delete
        if ((c == 0x7F or c == 0x08) and i > 0) {
            i -= 1;
            _ = sys.esp_rom_printf("\x08 \x08"); // erase char on terminal
            continue;
        }
        // Ignore other control characters
        if (c < 0x20) continue;
        buf[i] = c;
        i += 1;
        // Echo character back to terminal
        _ = sys.esp_rom_printf("%c", @as(c_int, c));
    }
    buf[i] = 0;
    return buf[0..i];
}

// ─── Configuration (from sdkconfig via Kconfig) ────────────────────────
const API_URL: [*:0]const u8 = sys.CONFIG_NULLCLAW_LLM_API_URL;
const API_KEY: [*:0]const u8 = sys.CONFIG_NULLCLAW_LLM_API_KEY;
const MODEL: [*:0]const u8 = sys.CONFIG_NULLCLAW_LLM_MODEL;

// ─── Provider: system prompt & tool schemas (mirrors providers/openai.zig)
const SYSTEM_PROMPT =
    \\You are NullClaw, an embedded AI assistant on ESP32-S3 with protocol tools.
    \\Tools: gpio_set, file_create, uart_tx, spi_transfer, i2c_scan, i2c_write, i2c_read.
    \\GPIO pins: 0-21, 35-48. Pins 22-34 are input-only (no output). Avoid GPIO 0,1,3,44,45.
    \\uart_tx: bit-bang UART on any output pin (baud: 300-115200). Data is hex-encoded.
    \\spi_transfer: bit-bang SPI (Mode 0). Data is hex-encoded.
    \\i2c_scan: scan I2C bus for devices. Returns list of found addresses.
    \\i2c_write/read: bit-bang I2C (7-bit address). Data is hex-encoded.
    \\Always use i2c_scan before i2c_write/read to find device addresses.
    \\Max 3 concurrent protocol operations (FreeRTOS task pool). Be concise.
;

const TOOLS_JSON =
    \\[{"type":"function","function":{"name":"gpio_set","description":"Set GPIO pin level (0-21, 35-48 output; 1-21, 35-48 input ok)","parameters":{"type":"object","properties":{"pin":{"type":"integer","description":"GPIO pin 0-48"},"level":{"type":"integer","description":"0=low 1=high"}},"required":["pin","level"]}}},
    \\{"type":"function","function":{"name":"file_create","description":"Create a file","parameters":{"type":"object","properties":{"path":{"type":"string","description":"File path"},"content":{"type":"string","description":"File content"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"uart_tx","description":"Send bytes via software UART (bit-bang).","parameters":{"type":"object","properties":{"pin":{"type":"integer","description":"TX GPIO pin (output-capable: 0-21,35-48)"},"baud":{"type":"integer","description":"Baud rate (300-115200)"},"data":{"type":"string","description":"Hex-encoded bytes, e.g. '48656C6C6F' for 'Hello'"}},"required":["pin","baud","data"]}}},
    \\{"type":"function","function":{"name":"spi_transfer","description":"Bit-bang SPI Mode 0 transfer. Returns hex MISO data.","parameters":{"type":"object","properties":{"clk":{"type":"integer","description":"CLK GPIO"},"mosi":{"type":"integer","description":"MOSI GPIO"},"miso":{"type":"integer","description":"MISO GPIO (-1 if none)"},"cs":{"type":"integer","description":"CS GPIO (-1 if none)"},"data":{"type":"string","description":"Hex-encoded TX data"},"clock_hz":{"type":"integer","description":"SPI clock Hz"}},"required":["clk","mosi","miso","cs","data","clock_hz"]}}},
    \\{"type":"function","function":{"name":"i2c_scan","description":"Scan I2C bus for all responding devices (0x03-0x77).","parameters":{"type":"object","properties":{"sda":{"type":"integer","description":"SDA GPIO pin"},"scl":{"type":"integer","description":"SCL GPIO pin"}},"required":["sda","scl"]}}},
    \\{"type":"function","function":{"name":"i2c_write","description":"Bit-bang I2C write to 7-bit address.","parameters":{"type":"object","properties":{"sda":{"type":"integer","description":"SDA GPIO"},"scl":{"type":"integer","description":"SCL GPIO"},"addr":{"type":"integer","description":"7-bit I2C address (0x03-0x77)"},"data":{"type":"string","description":"Hex-encoded bytes"}},"required":["sda","scl","addr","data"]}}},
    \\{"type":"function","function":{"name":"i2c_read","description":"Bit-bang I2C read from 7-bit address. Returns hex data.","parameters":{"type":"object","properties":{"sda":{"type":"integer","description":"SDA GPIO"},"scl":{"type":"integer","description":"SCL GPIO"},"addr":{"type":"integer","description":"7-bit I2C address (0x03-0x77)"},"len":{"type":"integer","description":"Bytes to read (max 64)"}},"required":["sda","scl","addr","len"]}}}]
;

// ═══════════════════════════════════════════════════════════════════════════════
// WiFi Connection
// ═══════════════════════════════════════════════════════════════════════════════

var g_event_group: sys.EventGroupHandle_t = null;
var g_retry_count: u32 = 0;
const CONNECTED_BIT: u32 = sys.WIFI_CONNECTED_BIT;
const FAILED_BIT: u32 = sys.WIFI_FAIL_BIT;

export fn ncWifiEvent(_: ?*anyopaque, _: sys.esp_event_base_t, event_id: i32, _: ?*anyopaque) callconv(.c) void {
    if (event_id == sys.WIFI_EVENT_STA_START) {
        idf.wifi.connect() catch {};
    } else if (event_id == sys.WIFI_EVENT_STA_DISCONNECTED) {
        if (g_retry_count < 5) {
            g_retry_count += 1;
            idf.wifi.connect() catch {};
        } else {
            _ = sys.xEventGroupSetBits(g_event_group, FAILED_BIT);
        }
    }
}

export fn ncIpEvent(_: ?*anyopaque, _: sys.esp_event_base_t, event_id: i32, event_data: ?*anyopaque) callconv(.c) void {
    if (event_id == sys.IP_EVENT_STA_GOT_IP) {
        const ev = @as(*sys.ip_event_got_ip_t, @ptrCast(@alignCast(event_data)));
        const ip = ev.ip_info.ip.addr;
        _ = sys.esp_rom_printf("[wifi] IP: %d.%d.%d.%d\r\n", @as(u8, @truncate(ip)), @as(u8, @truncate(ip >> 8)), @as(u8, @truncate(ip >> 16)), @as(u8, @truncate(ip >> 24)));
        g_retry_count = 0;
        _ = sys.xEventGroupSetBits(g_event_group, CONNECTED_BIT);
    }
}

fn wifiConnect() !void {
    g_event_group = sys.xEventGroupCreate() orelse return error.EventGroupCreateFailed;
    try idf.err.espCheckError(sys.esp_netif_init());
    try idf.event.loopCreateDefault();
    _ = sys.esp_netif_create_default_wifi_sta();

    // Use C wrapper to get proper WIFI_INIT_CONFIG_DEFAULT()
    var cfg: sys.wifi_init_config_t = undefined;
    wifi_get_default_config(&cfg);
    try idf.err.espCheckError(sys.esp_wifi_init(&cfg));

    _ = try idf.event.handlerInstanceRegister(sys.WIFI_EVENT, idf.event.ANY_ID, &ncWifiEvent, null);
    _ = try idf.event.handlerInstanceRegister(sys.IP_EVENT, sys.IP_EVENT_STA_GOT_IP, &ncIpEvent, null);

    // Use patched wifi_sta_config_t (wifi_config_t is opaque in bindings)
    var sta_cfg = std.mem.zeroes(sys.wifi_sta_config_t);
    copyZ(&sta_cfg.ssid, sys.CONFIG_ESP_WIFI_SSID);
    copyZ(&sta_cfg.password, sys.CONFIG_ESP_WIFI_PASSWORD);
    sta_cfg.threshold.authmode = sys.WIFI_AUTH_WPA2_PSK;
    sta_cfg.sae_pwe_h2e = sys.WPA3_SAE_PWE_BOTH;

    try idf.wifi.setMode(.WIFI_MODE_STA);
    try idf.wifi.setConfig(.WIFI_IF_STA, @ptrCast(&sta_cfg));
    try idf.wifi.start();

    _ = sys.esp_rom_printf("[wifi] Connecting to %s...\r\n", sys.CONFIG_ESP_WIFI_SSID);

    const bits = sys.xEventGroupWaitBits(g_event_group, CONNECTED_BIT | FAILED_BIT, 0, 0, sys.portMAX_DELAY);
    if ((bits & CONNECTED_BIT) == 0) return error.WifiConnectionFailed;
}

fn copyZ(dst: anytype, src: [*:0]const u8) void {
    const N = @typeInfo(@typeInfo(@TypeOf(dst)).pointer.child).array.len;
    var i: usize = 0;
    while (i < N - 1) : (i += 1) {
        dst[i] = src[i];
        if (src[i] == 0) return;
    }
    dst[N - 1] = 0;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Provider: OpenAI-compatible LLM API (mirrors providers/openai.zig)
// ═══════════════════════════════════════════════════════════════════════════════

// Static buffers to avoid stack overflow (16KB + 4KB on stack would blow 8KB limit)
var g_resp_buf: [16384]u8 = undefined;
var g_body_buf: [4096]u8 = undefined;
var g_auth_buf: [256]u8 = undefined;

fn callLLM(user_msg: []const u8) ![]const u8 {
    // Build request JSON manually (std.io not available on freestanding)
    var pos: usize = 0;

    pos += bufWrite(g_body_buf[pos..], "{\"model\":\"");
    pos += bufWrite(g_body_buf[pos..], std.mem.span(MODEL));
    pos += bufWrite(g_body_buf[pos..], "\",\"messages\":[{\"role\":\"system\",\"content\":\"");
    pos += bufWriteJsonStr(g_body_buf[pos..], SYSTEM_PROMPT);
    pos += bufWrite(g_body_buf[pos..], "\"},{\"role\":\"user\",\"content\":\"");
    pos += bufWriteJsonStr(g_body_buf[pos..], user_msg);
    pos += bufWrite(g_body_buf[pos..], "\"}],\"tools\":");
    pos += bufWrite(g_body_buf[pos..], TOOLS_JSON);
    g_body_buf[pos] = '}';
    pos += 1;
    const body = g_body_buf[0..pos];

    const auth = std.fmt.bufPrintZ(&g_auth_buf, "Bearer {s}", .{std.mem.span(API_KEY)}) catch return error.AuthTooLong;

    var http_cfg = std.mem.zeroes(sys.esp_http_client_config_t);
    http_cfg.url = API_URL;
    http_cfg.timeout_ms = 10000;
    http_cfg.crt_bundle_attach = &sys.esp_crt_bundle_attach;

    var client = idf.http.Client.init(&http_cfg);
    defer client.deinit() catch {};

    idf.http.Client.Set.method(client.handle, @intCast(sys.HTTP_METHOD_POST)) catch return error.HttpCfg;
    idf.http.Client.Set.header(client.handle, "Content-Type", "application/json") catch return error.HttpCfg;
    idf.http.Client.Set.header(client.handle, "Authorization", auth) catch return error.HttpCfg;
    idf.http.Client.Set.postField(client.handle, body) catch return error.HttpCfg;

    _ = sys.esp_rom_printf("[llm] Requesting %s...\r\n", sys.CONFIG_NULLCLAW_LLM_MODEL);

    // Manual HTTP flow: open() → write body → fetchHeaders() → read()
    // perform() consumes the response internally, so read() returns 0 after it.
    client.open(@intCast(body.len)) catch |err| {
        _ = sys.esp_rom_printf("[llm] open err: %s\r\n", @errorName(err).ptr);
        return error.HttpFailed;
    };
    _ = client.write(body) catch |err| {
        _ = sys.esp_rom_printf("[llm] write err: %s\r\n", @errorName(err).ptr);
        client.close() catch {};
        return error.HttpFailed;
    };
    _ = client.fetchHeaders();
    const status = client.getStatusCode();
    if (status != 200) {
        _ = sys.esp_rom_printf("[llm] HTTP status: %d\r\n", status);
        client.close() catch {};
        return error.HttpBadStatus;
    }
    const content_len = client.getContentLength();
    _ = sys.esp_rom_printf("[llm] content-length: %d\r\n", @as(c_int, @intCast(content_len)));

    var total: i64 = 0;
    const want: i64 = if (content_len > 0) content_len else @as(i64, @intCast(g_resp_buf.len));
    while (total < want) {
        const remaining: c_int = @intCast(@min(want - total, 4096));
        const n = sys.esp_http_client_read(client.handle, @ptrCast(g_resp_buf[@intCast(total)..].ptr), remaining);
        if (n <= 0) break;
        total += n;
    }
    client.close() catch {};
    _ = sys.esp_rom_printf("[llm] Read %d bytes\r\n", @as(c_int, @intCast(total)));
    if (total == 0) return error.HttpReadFailed;

    // Return a direct slice of the static buffer — no allocation needed.
    // The caller must parse JSON before the next callLLM overwrites the buffer.
    return g_resp_buf[0..@intCast(total)];
}

fn bufWrite(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn bufWriteJsonStr(dst: []u8, s: []const u8) usize {
    var pos: usize = 0;
    for (s) |ch| {
        if (pos >= dst.len) break;
        const esc = switch (ch) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (esc) |e| {
            const n = @min(dst.len - pos, e.len);
            @memcpy(dst[pos .. pos + n], e[0..n]);
            pos += n;
        } else {
            dst[pos] = ch;
            pos += 1;
        }
    }
    return pos;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Hex encode/decode helpers
// ═══════════════════════════════════════════════════════════════════════════════

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn hexDecode(hex: []const u8, out: []u8) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i + 1 < hex.len and o < out.len) : (i += 2) {
        const hi = hexDigit(hex[i]) orelse break;
        const lo = hexDigit(hex[i + 1]) orelse break;
        out[o] = (hi << 4) | lo;
        o += 1;
    }
    return o;
}

fn hexEncode(buf: []u8, data: []const u8) usize {
    const hex_chars = "0123456789abcdef";
    var pos: usize = 0;
    for (data) |b| {
        if (pos + 2 > buf.len) break;
        buf[pos] = hex_chars[b >> 4];
        buf[pos + 1] = hex_chars[b & 0x0F];
        pos += 2;
    }
    return pos;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tools (mirrors tools/gpio.zig, tools/file_write.zig)
// ═══════════════════════════════════════════════════════════════════════════════

// Static buffers for protocol operations (avoid stack overflow)
var g_proto_tx_buf: [64]u8 = undefined;
var g_proto_rx_buf: [64]u8 = undefined;
var g_hex_buf: [128]u8 = undefined;

fn executeTool(allocator: std.mem.Allocator, name: []const u8, args_str: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "gpio_set")) {
        return execGpioSet(allocator, args_str);
    } else if (std.mem.eql(u8, name, "file_create")) {
        return execFileCreate(allocator, args_str);
    } else if (std.mem.eql(u8, name, "uart_tx")) {
        return execUartTx(allocator, args_str);
    } else if (std.mem.eql(u8, name, "spi_transfer")) {
        return execSpiTransfer(allocator, args_str);
    } else if (std.mem.eql(u8, name, "i2c_scan")) {
        return execI2cScan(allocator, args_str);
    } else if (std.mem.eql(u8, name, "i2c_write")) {
        return execI2cWrite(allocator, args_str);
    } else if (std.mem.eql(u8, name, "i2c_read")) {
        return execI2cRead(allocator, args_str);
    }
    return "Unknown tool";
}

fn execGpioSet(allocator: std.mem.Allocator, args: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return "JSON parse error";
    defer parsed.deinit();

    const pin_val = (parsed.value.object.get("pin") orelse return "missing 'pin'").integer;
    const level_val = (parsed.value.object.get("level") orelse return "missing 'level'").integer;

    const pin: idf.gpio.GpioNum = @enumFromInt(@as(sys.gpio_num_t, @intCast(pin_val)));
    idf.gpio.Direction.set(pin, .output) catch |err| {
        return std.fmt.allocPrint(allocator, "GPIO direction error: {s}", .{@errorName(err)}) catch "GPIO error";
    };
    idf.gpio.Level.set(pin, @intCast(level_val)) catch |err| {
        return std.fmt.allocPrint(allocator, "GPIO level error: {s}", .{@errorName(err)}) catch "GPIO error";
    };

    _ = sys.esp_rom_printf("[tool] GPIO %d -> %d\r\n", @as(c_int, @intCast(pin_val)), @as(c_int, @intCast(level_val)));
    return std.fmt.allocPrint(allocator, "GPIO {d} set to {d}", .{ pin_val, level_val }) catch "OK";
}

fn execFileCreate(allocator: std.mem.Allocator, args: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return "JSON parse error";
    defer parsed.deinit();

    const path_val = parsed.value.object.get("path") orelse return "missing 'path'";
    const content_val = parsed.value.object.get("content") orelse return "missing 'content'";
    if (path_val != .string or content_val != .string) return "type error";

    const path = path_val.string;
    const content = content_val.string;

    // Use NVS to store file content (key=path truncated to 15 chars, value=content)
    var nvs_handle: sys.nvs_handle_t = 0;
    if (sys.nvs_open("files", 1, &nvs_handle) != 0) { // 1 = NVS_READWRITE
        return "NVS open error";
    }
    defer sys.nvs_close(nvs_handle);

    // Truncate key to 15 chars (NVS limit)
    var key_buf: [16]u8 = undefined;
    const key_len = @min(path.len, 15);
    @memcpy(key_buf[0..key_len], path[0..key_len]);
    key_buf[key_len] = 0;

    if (sys.nvs_set_str(nvs_handle, @as([*c]const u8, @ptrCast(&key_buf)), @as([*c]const u8, @ptrCast(content.ptr))) != 0) {
        return "NVS write error";
    }
    _ = sys.nvs_commit(nvs_handle);

    _ = sys.esp_rom_printf("[tool] Stored in NVS (%d bytes)\r\n", @as(c_int, @intCast(content.len)));
    return std.fmt.allocPrint(allocator, "Stored {s} ({d} bytes)", .{ path, content.len }) catch "OK";
}

// ─── Protocol tools ─────────────────────────────────────────────────────

fn validateGpio(pin: i64) ?c_int {
    if (pin < 0 or pin > 48) return null;
    // Pins 22-34 are input-only on ESP32-S3, can't use for output protocols
    if (pin >= 22 and pin <= 34) return null;
    // Pins 0,1,3,44,45 are strapping pins, avoid
    if (pin == 0 or pin == 1 or pin == 3 or pin == 44 or pin == 45) return null;
    return @intCast(pin);
}

fn execUartTx(allocator: std.mem.Allocator, args: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return "JSON parse error";
    defer parsed.deinit();

    const pin_raw = (parsed.value.object.get("pin") orelse return "missing 'pin'").integer;
    const pin = validateGpio(pin_raw) orelse return "invalid GPIO pin (use 0-21 or 35-48, avoid 0,1,3,44,45)";
    const baud_val = (parsed.value.object.get("baud") orelse return "missing 'baud'").integer;
    const data_hex = (parsed.value.object.get("data") orelse return "missing 'data'").string;

    const data_len = hexDecode(data_hex, &g_proto_tx_buf);
    if (data_len == 0) return "invalid hex data";

    _ = sys.esp_rom_printf("[tool] UART TX pin=%d baud=%d len=%d\r\n", pin, @as(c_int, @intCast(baud_val)), @as(c_int, @intCast(data_len)));

    const sent = proto_uart_tx_sync(pin, @intCast(baud_val), &g_proto_tx_buf, @intCast(data_len));
    if (sent < 0) return "UART TX failed";
    return std.fmt.allocPrint(allocator, "UART TX: {d} bytes sent at {d} baud", .{ sent, baud_val }) catch "OK";
}

fn execSpiTransfer(allocator: std.mem.Allocator, args: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return "JSON parse error";
    defer parsed.deinit();

    const clk = validateGpio((parsed.value.object.get("clk") orelse return "missing 'clk'").integer) orelse return "invalid CLK GPIO";
    const mosi = validateGpio((parsed.value.object.get("mosi") orelse return "missing 'mosi'").integer) orelse return "invalid MOSI GPIO";
    const miso_raw = (parsed.value.object.get("miso") orelse return "missing 'miso'").integer;
    const miso: c_int = if (miso_raw < 0) -1 else (validateGpio(miso_raw) orelse return "invalid MISO GPIO");
    const cs_raw = (parsed.value.object.get("cs") orelse return "missing 'cs'").integer;
    const cs: c_int = if (cs_raw < 0) -1 else (validateGpio(cs_raw) orelse return "invalid CS GPIO");
    const data_hex = (parsed.value.object.get("data") orelse return "missing 'data'").string;
    const hz_val = (parsed.value.object.get("clock_hz") orelse return "missing 'clock_hz'").integer;

    const data_len = hexDecode(data_hex, &g_proto_tx_buf);
    if (data_len == 0) return "invalid hex data";

    @memset(&g_proto_rx_buf, 0);

    _ = sys.esp_rom_printf("[tool] SPI clk=%d mosi=%d miso=%d cs=%d len=%d hz=%d\r\n", clk, mosi, miso, cs, @as(c_int, @intCast(data_len)), @as(c_int, @intCast(hz_val)));

    const xfer = proto_spi_transfer_sync(clk, mosi, miso, cs, &g_proto_tx_buf, &g_proto_rx_buf, @intCast(data_len), @intCast(hz_val));
    if (xfer < 0) return "SPI transfer failed";

    const rx_hex_len = hexEncode(&g_hex_buf, g_proto_rx_buf[0..@intCast(xfer)]);
    return std.fmt.allocPrint(allocator, "SPI RX: {s}", .{g_hex_buf[0..rx_hex_len]}) catch "OK";
}

fn execI2cWrite(allocator: std.mem.Allocator, args: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return "JSON parse error";
    defer parsed.deinit();

    const sda = validateGpio((parsed.value.object.get("sda") orelse return "missing 'sda'").integer) orelse return "invalid SDA GPIO";
    const scl = validateGpio((parsed.value.object.get("scl") orelse return "missing 'scl'").integer) orelse return "invalid SCL GPIO";
    const addr_raw = (parsed.value.object.get("addr") orelse return "missing 'addr'").integer;
    if (addr_raw < 0x03 or addr_raw > 0x77) return "I2C address must be 0x03-0x77";
    const addr: u8 = @intCast(addr_raw);
    const data_hex = (parsed.value.object.get("data") orelse return "missing 'data'").string;

    const data_len = hexDecode(data_hex, &g_proto_tx_buf);
    if (data_len == 0) return "invalid hex data";

    _ = sys.esp_rom_printf("[tool] I2C write addr=0x%02x len=%d\r\n", @as(c_int, addr), @as(c_int, @intCast(data_len)));

    const written = proto_i2c_write_sync(sda, scl, addr, &g_proto_tx_buf, @intCast(data_len));
    if (written == -2) return "I2C NACK on address — device not found";
    if (written < 0) return "I2C write failed";
    return std.fmt.allocPrint(allocator, "I2C write: {d} bytes to addr 0x{x}", .{ written, @as(usize, addr) }) catch "OK";
}

fn execI2cRead(allocator: std.mem.Allocator, args: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return "JSON parse error";
    defer parsed.deinit();

    const sda = validateGpio((parsed.value.object.get("sda") orelse return "missing 'sda'").integer) orelse return "invalid SDA GPIO";
    const scl = validateGpio((parsed.value.object.get("scl") orelse return "missing 'scl'").integer) orelse return "invalid SCL GPIO";
    const addr_raw = (parsed.value.object.get("addr") orelse return "missing 'addr'").integer;
    if (addr_raw < 0x03 or addr_raw > 0x77) return "I2C address must be 0x03-0x77";
    const addr: u8 = @intCast(addr_raw);
    const len_val = (parsed.value.object.get("len") orelse return "missing 'len'").integer;

    const read_len: usize = @intCast(@min(len_val, 64));

    _ = sys.esp_rom_printf("[tool] I2C read addr=0x%02x len=%d\r\n", @as(c_int, addr), @as(c_int, @intCast(read_len)));

    const n = proto_i2c_read_sync(sda, scl, addr, &g_proto_rx_buf, @intCast(read_len));
    if (n == -2) return "I2C NACK on address — device not found";
    if (n < 0) return "I2C read failed";

    const rx_hex_len = hexEncode(&g_hex_buf, g_proto_rx_buf[0..@intCast(n)]);
    return std.fmt.allocPrint(allocator, "I2C RX: {s}", .{g_hex_buf[0..rx_hex_len]}) catch "OK";
}

fn execI2cScan(allocator: std.mem.Allocator, args: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return "JSON parse error";
    defer parsed.deinit();

    const sda = validateGpio((parsed.value.object.get("sda") orelse return "missing 'sda'").integer) orelse return "invalid SDA GPIO";
    const scl = validateGpio((parsed.value.object.get("scl") orelse return "missing 'scl'").integer) orelse return "invalid SCL GPIO";

    _ = sys.esp_rom_printf("[tool] I2C scan sda=%d scl=%d\r\n", sda, scl);

    const found = proto_i2c_scan(sda, scl);

    // Build result string listing found addresses
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    pos += bufWrite(buf[pos..], "Found devices at:");
    var count: usize = 0;
    for (0x03..0x78) |addr| {
        if ((found & (@as(u32, 1) << @intCast(addr))) != 0) {
            const hex_chars = "0123456789abcdef";
            if (pos + 5 < buf.len) {
                buf[pos] = ' ';
                buf[pos + 1] = '0';
                buf[pos + 2] = 'x';
                buf[pos + 3] = hex_chars[addr >> 4];
                buf[pos + 4] = hex_chars[addr & 0x0F];
                pos += 5;
            }
            count += 1;
            _ = sys.esp_rom_printf("[scan] 0x%02x\r\n", @as(c_int, @intCast(addr)));
        }
    }
    if (count == 0) {
        return "No I2C devices found";
    }
    return allocator.dupe(u8, buf[0..pos]) catch "OK";
}

// ═══════════════════════════════════════════════════════════════════════════════
// Agent: ReAct Tool-Calling Loop (mirrors agent.zig)
// ═══════════════════════════════════════════════════════════════════════════════

fn agentTurn(allocator: std.mem.Allocator, user_input: []const u8) void {
    var input_buf: [1024]u8 = undefined;
    @memcpy(input_buf[0..user_input.len], user_input);
    var input_len = user_input.len;

    for (0..3) |_| {
        const response = callLLM(input_buf[0..input_len]) catch |err| {
            _ = sys.esp_rom_printf("[LLM err: %s]\r\n", @errorName(err).ptr);
            return;
        };

        // Per-iteration arena for JSON parsing + tool execution — freed at end
        var iter_arena = std.heap.ArenaAllocator.init(allocator);
        const ia = iter_arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, ia, response, .{}) catch |err| {
            _ = sys.esp_rom_printf("[JSON err: %s, len=%d]\r\n", @errorName(err).ptr, @as(c_int, @intCast(response.len)));
            iter_arena.deinit();
            return;
        };

        const root = parsed.value;

        if (root.object.get("error")) |err_obj| {
            if (err_obj.object.get("message")) |msg| {
                if (msg == .string) {
                    uartWrite("[API error] ");
                    uartWriteLn(msg.string);
                    return;
                }
            }
            uartWriteLn("[API error]");
            return;
        }

        const choices = root.object.get("choices") orelse {
            uartWriteLn("[No choices]");
            return;
        };
        if (choices.array.items.len == 0) {
            uartWriteLn("[Empty response]");
            return;
        }
        const message = choices.array.items[0].object.get("message") orelse {
            uartWriteLn("[No message]");
            return;
        };

        if (message.object.get("tool_calls")) |tc| {
            if (tc == .array and tc.array.items.len > 0) {
                // Execute ALL tool calls in the response, not just the first one
                for (tc.array.items) |tc_item| {
                    const func = tc_item.object.get("function") orelse continue;
                    const name_val = func.object.get("name") orelse continue;
                    const args_val = func.object.get("arguments") orelse continue;
                    if (name_val != .string or args_val != .string) continue;

                    const name = name_val.string;
                    const tool_args = args_val.string;

                    uartWrite("[agent] Tool: ");
                    uartWriteLn(name);
                    const result = executeTool(ia, name, tool_args);

                    const suffix = std.fmt.bufPrint(input_buf[input_len..], "\n\n[Tool '{s}' result: {s}]", .{ name, result }) catch break;
                    input_len += suffix.len;
                }
                parsed.deinit();
                iter_arena.deinit();
                continue;
            }
        }

        if (message.object.get("content")) |content| {
            if (content == .string and content.string.len > 0) {
                uartWriteLn(content.string);
            } else {
                uartWriteLn("[No content]");
            }
        }
        parsed.deinit();
        iter_arena.deinit();
        return;
    }
    uartWriteLn("[Max tool rounds reached]");
}

// ═══════════════════════════════════════════════════════════════════════════════
// Entry Point
// ═══════════════════════════════════════════════════════════════════════════════

export fn app_main() callconv(.c) void {
    var heap = idf.heap.HeapCapsAllocator.init(.{ .@"8bit" = true });
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // Set up UART0 driver + VFS for stdin so console_getchar() works
    init_console_uart();
    // Init protocol engine (bit-bang UART/SPI/I2C + 3-task pool)
    proto_init();

    idf.nvs.flashInitOrErase() catch |err| {
        _ = sys.esp_rom_printf("[nvs] Error: %s\r\n", @errorName(err).ptr);
        return;
    };

    wifiConnect() catch |err| {
        _ = sys.esp_rom_printf("[wifi] Error: %s\r\n", @errorName(err).ptr);
        return;
    };

    // Disable WiFi power-save to reduce peak current draw
    _ = sys.esp_wifi_set_ps(sys.WIFI_PS_NONE);
    // Sync system clock via NTP — required for TLS certificate validation
    sync_time();

    uartWriteLn("");
    uartWriteLn("+------------------------------------------+");
    uartWriteLn("|     NullClaw ESP32 PoC  --  Ready!       |");
    uartWriteLn("|  AI agent with GPIO + file tools         |");
    uartWriteLn("|  Type a message, or 'quit' to exit.      |");
    uartWriteLn("+------------------------------------------+");
    uartWriteLn("");

    var input_buf: [256]u8 = undefined;
    while (true) {
        uartWrite("> ");
        const input = uartReadLine(&input_buf) orelse continue;
        if (input.len == 0) continue;
        if (std.mem.eql(u8, input, "quit") or std.mem.eql(u8, input, "exit")) {
            uartWriteLn("Bye!");
            break;
        }
        agentTurn(allocator, input);
    }
}

pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = idf.log.espLogFn,
};
