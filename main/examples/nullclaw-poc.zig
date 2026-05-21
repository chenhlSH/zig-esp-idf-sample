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

// ─── UART0 console I/O (uses ESP-IDF sys bindings, no @cImport) ───────
const UART_PORT: sys.uart_port_t = 0;

fn uartWrite(s: []const u8) void {
    _ = sys.uart_write_bytes(UART_PORT, s.ptr, s.len);
}

fn uartWriteLn(s: []const u8) void {
    uartWrite(s);
    uartWrite("\r\n");
}

fn uartReadLine(buf: []u8) ?[]u8 {
    if (!sys.uart_is_driver_installed(UART_PORT)) return null;
    var i: usize = 0;
    while (i < buf.len - 1) {
        var byte: [1]u8 = undefined;
        const n = sys.uart_read_bytes(UART_PORT, &byte, 1, sys.portMAX_DELAY);
        if (n <= 0) continue;
        const ch = byte[0];
        if (ch == '\n' or ch == '\r') {
            if (i > 0) break;
            continue;
        }
        buf[i] = ch;
        i += 1;
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
    \\You are NullClaw, an embedded AI assistant on ESP32-S3.
    \\Tools: gpio_set(pin,level) and file_create(path,content).
    \\Use tools when asked to control hardware or create files. Be concise.
;

const TOOLS_JSON =
    \\[{"type":"function","function":{"name":"gpio_set","description":"Set GPIO pin level","parameters":{"type":"object","properties":{"pin":{"type":"integer","description":"GPIO pin number"},"level":{"type":"integer","description":"0=low 1=high"}},"required":["pin","level"]}}},
    \\{"type":"function","function":{"name":"file_create","description":"Create a file","parameters":{"type":"object","properties":{"path":{"type":"string","description":"File path"},"content":{"type":"string","description":"File content"}},"required":["path","content"]}}}]
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

    // Set osi_funcs via @extern (direct reference has @compileError in bindings)
    const osi_ptr = @extern(*sys.wifi_osi_funcs_t, .{ .name = "g_wifi_osi_funcs" });
    var cfg = std.mem.zeroes(sys.wifi_init_config_t);
    cfg.osi_funcs = osi_ptr;
    cfg.wpa_crypto_funcs = sys.g_wifi_default_wpa_crypto_funcs;
    // Fill buffer counts from sdkconfig defaults (zero is invalid)
    cfg.static_rx_buf_num = 10;
    cfg.dynamic_rx_buf_num = 32;
    cfg.tx_buf_type = 1;
    cfg.static_tx_buf_num = 0;
    cfg.dynamic_tx_buf_num = 32;
    cfg.rx_mgmt_buf_type = 0;
    cfg.rx_mgmt_buf_num = 5;
    cfg.mgmt_sbuf_num = 32;
    cfg.ampdu_rx_enable = 1;
    cfg.ampdu_tx_enable = 1;
    cfg.nvs_enable = 1;
    cfg.rx_ba_win = 6;
    cfg.beacon_max_len = 752;
    cfg.tx_hetb_queue_num = 1;
    cfg.magic = 0x1F2F3F4F; // WIFI_INIT_CONFIG_MAGIC — required by driver
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

fn callLLM(allocator: std.mem.Allocator, user_msg: []const u8) ![]u8 {
    // Build request JSON manually (std.io not available on freestanding)
    var body_buf: [4096]u8 = undefined;
    var pos: usize = 0;

    pos += bufWrite(body_buf[pos..], "{\"model\":\"");
    pos += bufWrite(body_buf[pos..], std.mem.span(MODEL));
    pos += bufWrite(body_buf[pos..], "\",\"messages\":[{\"role\":\"system\",\"content\":\"");
    pos += bufWriteJsonStr(body_buf[pos..], SYSTEM_PROMPT);
    pos += bufWrite(body_buf[pos..], "\"},{\"role\":\"user\",\"content\":\"");
    pos += bufWriteJsonStr(body_buf[pos..], user_msg);
    pos += bufWrite(body_buf[pos..], "\"}],\"tools\":");
    pos += bufWrite(body_buf[pos..], TOOLS_JSON);
    body_buf[pos] = '}';
    pos += 1;
    const body = body_buf[0..pos];

    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrintZ(&auth_buf, "Bearer {s}", .{std.mem.span(API_KEY)}) catch return error.AuthTooLong;

    var http_cfg = std.mem.zeroes(sys.esp_http_client_config_t);
    http_cfg.url = API_URL;
    http_cfg.skip_cert_common_name_check = true;

    var client = idf.http.Client.init(&http_cfg);
    defer client.deinit() catch {};

    idf.http.Client.Set.method(client.handle, @intCast(sys.HTTP_METHOD_POST)) catch return error.HttpCfg;
    idf.http.Client.Set.header(client.handle, "Content-Type", "application/json") catch return error.HttpCfg;
    idf.http.Client.Set.header(client.handle, "Authorization", auth) catch return error.HttpCfg;
    idf.http.Client.Set.postField(client.handle, body) catch return error.HttpCfg;

    _ = sys.esp_rom_printf("[llm] Requesting %s...\r\n", sys.CONFIG_NULLCLAW_LLM_MODEL);

    client.perform() catch |err| {
        _ = sys.esp_rom_printf("[llm] HTTP error: %s\r\n", @errorName(err).ptr);
        return error.HttpFailed;
    };

    const status = client.getStatusCode();
    if (status != 200) {
        _ = sys.esp_rom_printf("[llm] HTTP status: %d\r\n", status);
        return error.HttpBadStatus;
    }

    var resp_buf: [16384]u8 = undefined;
    const n = client.readResponse(&resp_buf) catch |err| {
        _ = sys.esp_rom_printf("[llm] Read error: %s\r\n", @errorName(err).ptr);
        return error.HttpReadFailed;
    };

    return allocator.dupe(u8, resp_buf[0..@intCast(n)]);
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
// Tools (mirrors tools/gpio.zig, tools/file_write.zig)
// ═══════════════════════════════════════════════════════════════════════════════

fn executeTool(allocator: std.mem.Allocator, name: []const u8, args_str: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "gpio_set")) {
        return execGpioSet(allocator, args_str);
    } else if (std.mem.eql(u8, name, "file_create")) {
        return execFileCreate(allocator, args_str);
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

// ═══════════════════════════════════════════════════════════════════════════════
// Agent: ReAct Tool-Calling Loop (mirrors agent.zig)
// ═══════════════════════════════════════════════════════════════════════════════

fn agentTurn(allocator: std.mem.Allocator, user_input: []const u8) void {
    var turn_arena = std.heap.ArenaAllocator.init(allocator);
    defer turn_arena.deinit();
    const ta = turn_arena.allocator();

    var input_buf: [1024]u8 = undefined;
    @memcpy(input_buf[0..user_input.len], user_input);
    var input_len = user_input.len;

    for (0..3) |_| {
        const response = callLLM(ta, input_buf[0..input_len]) catch {
            uartWriteLn("[LLM request failed]");
            return;
        };

        const parsed = std.json.parseFromSlice(std.json.Value, ta, response, .{}) catch {
            uartWriteLn("[JSON parse error]");
            return;
        };
        defer parsed.deinit();

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
                const tc_item = tc.array.items[0];
                const func = tc_item.object.get("function") orelse continue;
                const name_val = func.object.get("name") orelse continue;
                const args_val = func.object.get("arguments") orelse continue;
                if (name_val != .string or args_val != .string) continue;

                const name = name_val.string;
                const tool_args = args_val.string;

                _ = sys.esp_rom_printf("[agent] Tool: %s\r\n", name.ptr);
                const result = executeTool(ta, name, tool_args);

                const suffix = std.fmt.bufPrint(input_buf[input_len..], "\n\n[Tool '{s}' result: {s}]", .{ name, result }) catch break;
                input_len += suffix.len;
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

    idf.nvs.flashInitOrErase() catch |err| {
        _ = sys.esp_rom_printf("[nvs] Error: %s\r\n", @errorName(err).ptr);
        return;
    };

    wifiConnect() catch |err| {
        _ = sys.esp_rom_printf("[wifi] Error: %s\r\n", @errorName(err).ptr);
        return;
    };

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
