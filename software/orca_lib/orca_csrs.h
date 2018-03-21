#ifndef __ORCA_CSRS_H
#define __ORCA_CSRS_H

#include "encoding.h"

#define STRINGIFY_CSR(CSR_NUMBER) #CSR_NUMBER
#define CSR_STRING(CSR_NUMBER)    STRINGIFY_CSR(CSR_NUMBER)

#define CSR_MEIMASK 0x7C0
#define CSR_MEIPEND 0xFC0

#define CSR_MCACHE 0xBC0

#define CSR_MAMR0_BASE 0xBD0
#define CSR_MAMR1_BASE 0xBD1
#define CSR_MAMR2_BASE 0xBD2
#define CSR_MAMR3_BASE 0xBD3
#define CSR_MAMR0_LAST 0xBD8
#define CSR_MAMR1_LAST 0xBD9
#define CSR_MAMR2_LAST 0xBDA
#define CSR_MAMR3_LAST 0xBDB
#define CSR_MUMR0_BASE 0xBE0
#define CSR_MUMR1_BASE 0xBE1
#define CSR_MUMR2_BASE 0xBE2
#define CSR_MUMR3_BASE 0xBE3
#define CSR_MUMR0_LAST 0xBE8
#define CSR_MUMR1_LAST 0xBE9
#define CSR_MUMR2_LAST 0xBEA
#define CSR_MUMR3_LAST 0xBEB


//MCACHE bits implemented in ORCA
#define MCACHE_IEXISTS 0x00000001
#define MCACHE_DEXISTS 0x00000002

#ifndef stringify
#define _stringify(a) #a
#define stringify(a) _stringify(a)
#endif // stringify

#define csrr(name,dst) asm volatile ("csrr %0 ," stringify(name) :"=r"(dst) )
#define csrw(name,src) asm volatile ("csrw " stringify(name) ",%0" ::"r"(src) )

#endif //#ifndef __ORCA_CSRS_H
