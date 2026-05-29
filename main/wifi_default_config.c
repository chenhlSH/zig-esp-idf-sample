// Thin C wrapper so Zig can call WIFI_INIT_CONFIG_DEFAULT() without
// trying to translate the C macro itself (which contains opaque symbols).

#include "esp_wifi.h"
#include "esp_sntp.h"
#include "driver/uart.h"
#include "driver/uart_vfs.h"
#include <stdio.h>
#include <time.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

void wifi_get_default_config(wifi_init_config_t *out)
{
    wifi_init_config_t tmp = WIFI_INIT_CONFIG_DEFAULT();
    *out = tmp;
}

// Initialise UART0 driver and route VFS stdin/stdout to it.
// Must be called once at startup before any console input.
void init_console_uart(void)
{
    const uart_config_t uart_cfg = {
        .baud_rate  = 115200,
        .data_bits  = UART_DATA_8_BITS,
        .parity     = UART_PARITY_DISABLE,
        .stop_bits  = UART_STOP_BITS_1,
        .flow_ctrl  = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    // Install UART0 driver: rx_buf=512, tx_buf=0, no event queue
    uart_driver_install(UART_NUM_0, 512, 0, 0, NULL, 0);
    uart_param_config(UART_NUM_0, &uart_cfg);
    // Configure line endings
    uart_vfs_dev_port_set_rx_line_endings(0, ESP_LINE_ENDINGS_CR);
    uart_vfs_dev_port_set_tx_line_endings(0, ESP_LINE_ENDINGS_CRLF);
    // Route VFS to use UART driver (blocking, interrupt-driven)
    uart_vfs_dev_use_driver(0);
    // Flush any stale data in UART RX buffer
    uart_flush_input(UART_NUM_0);
}

// Read one character from UART0. Returns -1 if no data available.
// Uses non-blocking uart_read_bytes (tick=0) to avoid blocking the idle task.
int console_getchar(void)
{
    uint8_t ch;
    int n = uart_read_bytes(UART_NUM_0, &ch, 1, 0); // 0 ticks = non-blocking
    if (n <= 0) {
        // No data — yield to FreeRTOS idle task to prevent watchdog timeout
        vTaskDelay(pdMS_TO_TICKS(10));
        return -1;
    }
    return (int)ch;
}

// Print a prompt string to stdout (UART0 via VFS).
void console_puts(const char *s)
{
    puts(s);
}

// Start SNTP and wait until the system clock is synchronised (timeout 15 s).
// Must be called AFTER WiFi is connected.
void sync_time(void)
{
    esp_sntp_setoperatingmode(ESP_SNTP_OPMODE_POLL);
    esp_sntp_setservername(0, "pool.ntp.org");
    esp_sntp_init();

    time_t now = 0;
    struct tm tm_info = { 0 };
    int retry = 0;
    const int max_retries = 150;
    while (tm_info.tm_year < (2020 - 1900) && ++retry < max_retries) {
        vTaskDelay(pdMS_TO_TICKS(100));
        time(&now);
        localtime_r(&now, &tm_info);
    }
    if (tm_info.tm_year >= (2020 - 1900)) {
        printf("[time] Synced: %d-%02d-%02d %02d:%02d:%02d\n",
               tm_info.tm_year + 1900, tm_info.tm_mon + 1, tm_info.tm_mday,
               tm_info.tm_hour, tm_info.tm_min, tm_info.tm_sec);
    } else {
        printf("[time] NTP sync timed out\n");
    }
}
