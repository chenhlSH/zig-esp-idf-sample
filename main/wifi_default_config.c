// Thin C wrapper so Zig can call WIFI_INIT_CONFIG_DEFAULT() without
// trying to translate the C macro itself (which contains opaque symbols).

#include "esp_wifi.h"
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

void wifi_get_default_config(wifi_init_config_t *out)
{
    wifi_init_config_t tmp = WIFI_INIT_CONFIG_DEFAULT();
    *out = tmp;
}

// Read one character from stdin (UART0 via VFS). Returns -1 on error.
// Uses non-blocking read with short delay to avoid watchdog timeout.
int console_getchar(void)
{
    int ch = fgetc(stdin);
    if (ch == EOF) {
        // Yield to FreeRTOS idle task to prevent watchdog timeout
        vTaskDelay(pdMS_TO_TICKS(10));
        return -1;
    }
    return ch;
}

// Print a prompt string to stdout (UART0 via VFS).
void console_puts(const char *s)
{
    puts(s);
}
