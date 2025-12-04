#include "uart.h"

#define UART_BASE      0x10000000
#define REG_UART_RX    (*(volatile uint32_t*)(UART_BASE + 0))
#define REG_UART_TX    (*(volatile uint32_t*)(UART_BASE + 4))
#define REG_UART_STAT  (*(volatile uint32_t*)(UART_BASE + 8))

void uart_init(void)
{
    // Tidak perlu konfigurasi apa-apa di sini untuk saat ini.
}

int uart_rx_ready(void)
{
    // Asumsi: bit0 = RX data available (boleh disesuaikan kalau RTL beda)
    return (REG_UART_STAT & 1);
}

char uart_rx(void)
{
    return (char)(REG_UART_RX & 0xFF);
}

void uart_tx(char c)
{
    // DEBUG MODE: JANGAN NUNGGU STAT, LANGSUNG TULIS
    REG_UART_TX = (uint32_t)c;

    // Delay kecil supaya UART nggak keteteran kalau core terlalu cepat
    for (volatile int i = 0; i < 200; ++i) {
        // nop
    }
}

void uart_write_str(const char *s)
{
    while (*s) {
        uart_tx(*s++);
    }
}

static const char hex_digits[] = "0123456789ABCDEF";

void uart_write_hex8(uint8_t v)
{
    uart_tx(hex_digits[(v >> 4) & 0xF]);
    uart_tx(hex_digits[v & 0xF]);
}
