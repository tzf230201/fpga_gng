#ifndef UART_H
#define UART_H

#include <stdint.h>

void uart_init(void);
int  uart_rx_ready(void);
char uart_rx(void);
void uart_tx(char c);
void uart_write_str(const char *s);
void uart_write_hex8(uint8_t v);

#endif
