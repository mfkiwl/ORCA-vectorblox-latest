#ifndef __UART_H
#define __UART_H

#include <stdint.h>
#include <stdarg.h>

#define X_mWriteReg(BASE_ADDRESS, RegOffset, data)                    \
  (*((volatile uint32_t *)(((uintptr_t)BASE_ADDRESS) + RegOffset)) = (uint32_t)data)
#define X_mReadReg(BASE_ADDRESS, RegOffset)                             \
  (*((volatile uint32_t *)(((uintptr_t)BASE_ADDRESS) + RegOffset)))
#define XUartChanged_IsTransmitFull(BASE_ADDRESS)                       \
  ((X_mReadReg(BASE_ADDRESS, 0x2C) & 0x10) == 0x10)
#define XUartChanged_IsTransmitEmpty(BASE_ADDRESS)                       \
  ((X_mReadReg(BASE_ADDRESS, 0x2C) & 0x8) == 0x8)

void XUARTChanged_SendByte(volatile void *BaseAddress, uint8_t Data);
void outbyte(char c);
void ChangedPrint(char *ptr);
void print_char(char c);
void print_hex(uint32_t value);
void flush_uart(void);

#endif //#ifndef __UART_H
