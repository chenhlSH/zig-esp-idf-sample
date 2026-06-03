// Protocol engine — bit-bang UART/SPI/I2C using ESP32-S3 GPIO + esp_rom_delay_us
// Runs in dedicated FreeRTOS tasks (max 3 concurrent) to avoid blocking main thread.

#include "driver/gpio.h"
#include "esp_rom_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include <string.h>

// ═══════════════════════════════════════════════════════════════════════════
// Concurrency control — max 3 concurrent protocol operations
// ═══════════════════════════════════════════════════════════════════════════
#define MAX_CONCURRENT_TASKS 3
#define TASK_STACK_SIZE 4096
#define TASK_PRIORITY 5

static SemaphoreHandle_t s_task_slots = NULL;

void proto_init(void)
{
    if (s_task_slots == NULL) {
        s_task_slots = xSemaphoreCreateCounting(MAX_CONCURRENT_TASKS, MAX_CONCURRENT_TASKS);
    }
}

static bool acquire_slot(void)
{
    if (s_task_slots == NULL) proto_init();
    return xSemaphoreTake(s_task_slots, pdMS_TO_TICKS(30000)) == pdTRUE;
}

static void release_slot(void)
{
    if (s_task_slots != NULL) xSemaphoreGive(s_task_slots);
}

// ═══════════════════════════════════════════════════════════════════════════
// Precise GPIO helpers
// ═══════════════════════════════════════════════════════════════════════════
static inline void gpio_write(int pin, int level)
{
    gpio_set_level((gpio_num_t)pin, level);
}

static inline void delay_us(int us)
{
    esp_rom_delay_us(us);
}

// ═══════════════════════════════════════════════════════════════════════════
// Software UART TX (bit-bang)
// ═══════════════════════════════════════════════════════════════════════════
int proto_uart_tx(int tx_pin, int baud, const uint8_t *data, int len)
{
    if (tx_pin < 0 || baud <= 0 || !data || len <= 0) return -1;

    gpio_set_direction((gpio_num_t)tx_pin, GPIO_MODE_OUTPUT);
    gpio_write(tx_pin, 1); // idle high

    int bit_us = 1000000 / baud;
    int sent = 0;

    for (int i = 0; i < len; i++) {
        uint8_t byte = data[i];
        // Start bit
        gpio_write(tx_pin, 0);
        delay_us(bit_us);
        // 8 data bits (LSB first)
        for (int b = 0; b < 8; b++) {
            gpio_write(tx_pin, (byte >> b) & 1);
            delay_us(bit_us);
        }
        // Stop bit
        gpio_write(tx_pin, 1);
        delay_us(bit_us);
        sent++;
    }
    return sent;
}

// ═══════════════════════════════════════════════════════════════════════════
// Software SPI (Mode 0: CPOL=0, CPHA=0)
// ═══════════════════════════════════════════════════════════════════════════
int proto_spi_transfer(int clk_pin, int mosi_pin, int miso_pin, int cs_pin,
                       const uint8_t *tx_data, uint8_t *rx_data, int len, int clock_hz)
{
    if (clk_pin < 0 || mosi_pin < 0 || len <= 0) return -1;
    if (clock_hz <= 0) clock_hz = 100000;

    int half_period_us = 500000 / clock_hz;
    if (half_period_us < 1) half_period_us = 1;

    gpio_set_direction((gpio_num_t)clk_pin, GPIO_MODE_OUTPUT);
    gpio_set_direction((gpio_num_t)mosi_pin, GPIO_MODE_OUTPUT);
    if (miso_pin >= 0) gpio_set_direction((gpio_num_t)miso_pin, GPIO_MODE_INPUT);
    if (cs_pin >= 0) {
        gpio_set_direction((gpio_num_t)cs_pin, GPIO_MODE_OUTPUT);
        gpio_write(cs_pin, 0); // CS active low
    }

    gpio_write(clk_pin, 0); // clock idle low

    for (int i = 0; i < len; i++) {
        uint8_t tx_byte = tx_data ? tx_data[i] : 0xFF;
        uint8_t rx_byte = 0;

        for (int b = 7; b >= 0; b--) {
            // Setup MOSI
            gpio_write(mosi_pin, (tx_byte >> b) & 1);
            delay_us(half_period_us);
            // Rising edge — sample MISO
            gpio_write(clk_pin, 1);
            if (miso_pin >= 0) {
                rx_byte |= (gpio_get_level((gpio_num_t)miso_pin) << b);
            }
            delay_us(half_period_us);
            // Falling edge
            gpio_write(clk_pin, 0);
        }

        if (rx_data) rx_data[i] = rx_byte;
    }

    if (cs_pin >= 0) gpio_write(cs_pin, 1); // CS inactive
    return len;
}

// ═══════════════════════════════════════════════════════════════════════════
// Software I2C (100kHz standard mode)
// ═══════════════════════════════════════════════════════════════════════════
static int i2c_half_period_us = 5; // 100kHz = 5µs half-period

static void i2c_sda_high(int sda_pin) { gpio_set_direction((gpio_num_t)sda_pin, GPIO_MODE_INPUT); gpio_set_level((gpio_num_t)sda_pin, 1); }
static void i2c_sda_low(int sda_pin)  { gpio_set_direction((gpio_num_t)sda_pin, GPIO_MODE_OUTPUT); gpio_set_level((gpio_num_t)sda_pin, 0); }
static void i2c_scl_high(int scl_pin) { gpio_set_direction((gpio_num_t)scl_pin, GPIO_MODE_INPUT); gpio_set_level((gpio_num_t)scl_pin, 1); }
static void i2c_scl_low(int scl_pin)  { gpio_set_direction((gpio_num_t)scl_pin, GPIO_MODE_OUTPUT); gpio_set_level((gpio_num_t)scl_pin, 0); }

static void i2c_start(int sda_pin, int scl_pin)
{
    i2c_sda_high(sda_pin);
    i2c_scl_high(scl_pin);
    delay_us(i2c_half_period_us);
    i2c_sda_low(sda_pin);
    delay_us(i2c_half_period_us);
    i2c_scl_low(scl_pin);
    delay_us(i2c_half_period_us);
}

static void i2c_stop(int sda_pin, int scl_pin)
{
    i2c_sda_low(sda_pin);
    i2c_scl_high(scl_pin);
    delay_us(i2c_half_period_us);
    i2c_sda_high(sda_pin);
    delay_us(i2c_half_period_us);
}

static int i2c_write_byte(int sda_pin, int scl_pin, uint8_t byte)
{
    for (int b = 7; b >= 0; b--) {
        if ((byte >> b) & 1)
            i2c_sda_high(sda_pin);
        else
            i2c_sda_low(sda_pin);
        delay_us(i2c_half_period_us);
        i2c_scl_high(scl_pin);
        delay_us(i2c_half_period_us);
        i2c_scl_low(scl_pin);
        delay_us(i2c_half_period_us);
    }
    // Read ACK
    i2c_sda_high(sda_pin); // release SDA
    delay_us(i2c_half_period_us);
    i2c_scl_high(scl_pin);
    delay_us(i2c_half_period_us);
    int ack = gpio_get_level((gpio_num_t)sda_pin); // 0=ACK, 1=NACK
    i2c_scl_low(scl_pin);
    delay_us(i2c_half_period_us);
    return ack; // 0 = success
}

static uint8_t i2c_read_byte(int sda_pin, int scl_pin, bool send_ack)
{
    uint8_t byte = 0;
    i2c_sda_high(sda_pin); // release SDA
    for (int b = 7; b >= 0; b--) {
        delay_us(i2c_half_period_us);
        i2c_scl_high(scl_pin);
        delay_us(i2c_half_period_us);
        byte |= (gpio_get_level((gpio_num_t)sda_pin) << b);
        i2c_scl_low(scl_pin);
    }
    // Send ACK/NACK
    if (send_ack)
        i2c_sda_low(sda_pin);
    else
        i2c_sda_high(sda_pin);
    delay_us(i2c_half_period_us);
    i2c_scl_high(scl_pin);
    delay_us(i2c_half_period_us);
    i2c_scl_low(scl_pin);
    delay_us(i2c_half_period_us);
    return byte;
}

int proto_i2c_write(int sda_pin, int scl_pin, uint8_t addr,
                    const uint8_t *data, int len)
{
    if (sda_pin < 0 || scl_pin < 0) return -1;

    i2c_start(sda_pin, scl_pin);
    // Address + Write bit (0)
    if (i2c_write_byte(sda_pin, scl_pin, (addr << 1) | 0) != 0) {
        i2c_stop(sda_pin, scl_pin);
        return -2; // NACK on address
    }
    int written = 0;
    for (int i = 0; i < len; i++) {
        if (i2c_write_byte(sda_pin, scl_pin, data[i]) != 0) break;
        written++;
    }
    i2c_stop(sda_pin, scl_pin);
    return written;
}

int proto_i2c_read(int sda_pin, int scl_pin, uint8_t addr,
                   uint8_t *data, int len)
{
    if (sda_pin < 0 || scl_pin < 0 || !data || len <= 0) return -1;

    i2c_start(sda_pin, scl_pin);
    // Address + Read bit (1)
    if (i2c_write_byte(sda_pin, scl_pin, (addr << 1) | 1) != 0) {
        i2c_stop(sda_pin, scl_pin);
        return -2; // NACK on address
    }
    for (int i = 0; i < len; i++) {
        data[i] = i2c_read_byte(sda_pin, scl_pin, i < len - 1); // ACK all except last
    }
    i2c_stop(sda_pin, scl_pin);
    return len;
}

// ═══════════════════════════════════════════════════════════════════════════
// I2C bus scan — probe all addresses 0x03..0x77
// Returns bitmask of found devices (bit N = address N found)
// ═══════════════════════════════════════════════════════════════════════════
uint32_t proto_i2c_scan(int sda_pin, int scl_pin)
{
    uint32_t found = 0;
    for (uint8_t addr = 0x03; addr <= 0x77; addr++) {
        i2c_start(sda_pin, scl_pin);
        int ack = i2c_write_byte(sda_pin, scl_pin, (addr << 1) | 0);
        i2c_stop(sda_pin, scl_pin);
        if (ack == 0) {
            found |= (1U << addr);
        }
    }
    return found;
}

// ═══════════════════════════════════════════════════════════════════════════
// Task wrapper — runs protocol in a separate FreeRTOS task
// ═══════════════════════════════════════════════════════════════════════════
typedef enum {
    PROTO_UART_TX,
    PROTO_SPI_TRANSFER,
    PROTO_I2C_WRITE,
    PROTO_I2C_READ,
    PROTO_I2C_SCAN,
} proto_type_t;

typedef struct {
    proto_type_t type;
    int pins[4]; // [clk/tx/sda, mosi/scl, miso, cs]
    int baud_or_hz;
    uint8_t *tx_data;
    uint8_t *rx_data;
    int data_len;
    uint8_t i2c_addr;
    int result;        // output
    uint8_t result_buf[64]; // for rx data
} proto_request_t;

static void proto_task_func(void *arg)
{
    proto_request_t *req = (proto_request_t *)arg;

    switch (req->type) {
    case PROTO_UART_TX:
        req->result = proto_uart_tx(req->pins[0], req->baud_or_hz,
                                    req->tx_data, req->data_len);
        break;
    case PROTO_SPI_TRANSFER:
        req->result = proto_spi_transfer(req->pins[0], req->pins[1],
                                         req->pins[2], req->pins[3],
                                         req->tx_data, req->rx_data,
                                         req->data_len, req->baud_or_hz);
        break;
    case PROTO_I2C_WRITE:
        req->result = proto_i2c_write(req->pins[0], req->pins[1],
                                      req->i2c_addr, req->tx_data,
                                      req->data_len);
        break;
    case PROTO_I2C_READ:
        req->result = proto_i2c_read(req->pins[0], req->pins[1],
                                     req->i2c_addr, req->result_buf,
                                     req->data_len);
        break;
    case PROTO_I2C_SCAN:
        // Store scan result in result_buf as 4-byte uint32_t
        {
            uint32_t found = proto_i2c_scan(req->pins[0], req->pins[1]);
            memcpy(req->result_buf, &found, sizeof(found));
            req->result = (int)(found != 0 ? 0 : -1);
        }
        break;
    }

    release_slot();
    vTaskDelete(NULL);
}

// Launch a protocol operation in a separate task. Returns immediately.
// req must be statically allocated (persists until task finishes).
int proto_run_async(proto_request_t *req)
{
    if (!acquire_slot()) {
        req->result = -99; // timeout — no free slots
        return -1;
    }

    BaseType_t ret = xTaskCreate(
        proto_task_func,
        "proto",
        TASK_STACK_SIZE,
        req,
        TASK_PRIORITY,
        NULL
    );

    if (ret != pdPASS) {
        release_slot();
        req->result = -98;
        return -1;
    }
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Blocking convenience wrappers (run in caller's context)
// ═══════════════════════════════════════════════════════════════════════════
int proto_uart_tx_sync(int tx_pin, int baud, const uint8_t *data, int len)
{
    return proto_uart_tx(tx_pin, baud, data, len);
}

int proto_spi_transfer_sync(int clk_pin, int mosi_pin, int miso_pin, int cs_pin,
                             const uint8_t *tx_data, uint8_t *rx_data, int len, int clock_hz)
{
    return proto_spi_transfer(clk_pin, mosi_pin, miso_pin, cs_pin,
                              tx_data, rx_data, len, clock_hz);
}

int proto_i2c_write_sync(int sda_pin, int scl_pin, uint8_t addr,
                          const uint8_t *data, int len)
{
    return proto_i2c_write(sda_pin, scl_pin, addr, data, len);
}

int proto_i2c_read_sync(int sda_pin, int scl_pin, uint8_t addr,
                         uint8_t *data, int len)
{
    return proto_i2c_read(sda_pin, scl_pin, addr, data, len);
}
