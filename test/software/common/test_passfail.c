#include "test_passfail.h"
#include "printf.h"
#include "uart.h"

#define ALTERA 0
#define XILINX 0
#define MICROSEMI 0
#define LATTICE 0

// UART I/O is family specific.
// Edit the family above in to reflect the family
// being tested.

#if ALTERA
#define SYS_CLK 50000000 // Hz
volatile int *uart = (volatile int*) 0x01000070;
#define UART_INIT() ((void)0)
#define UART_PUTC(c) do {*((char*)uart) = (c);} while(0)
#define UART_BUSY() ((uart[1]&0xFFFF0000) == 0)
#define orca_printf printf
#endif

#if XILINX
#define SYS_CLK 25000000 // Hz
#define UART_INIT() ((void)0)
#define UART_PUTC(c) do {print_char(c);} while(0) 
#define UART_BUSY() 0 
#define orca_printf ChangedPrint

#endif

#if MICROSEMI
#define SYS_CLK 20000000 // Hz
#define UART_INIT() ((void)0)
#define UART_BASE  ((volatile int*) (0x30000000))
#define UART_DATA UART_BASE
#define UART_LSR   ((volatile int*) (0x30000010))
#define UART_PUTC(c) do{*UART_DATA = (c);} while(0)
#define UART_BUSY() (!((*UART_LSR) & 0x01))
#define orca_printf printf
#endif

#if LATTICE
#endif

static inline unsigned get_time() {
	int tmp;
	asm volatile("csrr %0, time":"=r"(tmp));
	return tmp;
}

static void delayus(int us) {
	unsigned start = get_time();
	us *= (SYS_CLK/1000000); // Cycles per us
	while(get_time()-start < us);
}

void mputc(void *p, char c) {
	while(UART_BUSY());
	UART_PUTC(c);
}

void test_pass(void) {
	init_printf(0, mputc);
  orca_printf("\r\nTest passed!\r\n");
  mputc(0, 4);
  while(1){
	}
}

void test_fail(void) {
	init_printf(0, mputc);
  orca_printf("\r\nTest failed with 1 error.\r\n");	
  mputc(0, 4);
	while(1){
	}
}
