#ifndef MDMA_CORE_PORTME_H
#define MDMA_CORE_PORTME_H

typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef unsigned int ee_u32;
typedef unsigned char ee_u8;
typedef unsigned long ee_ptr_int;
typedef unsigned long ee_size_t;
typedef ee_u32 CORE_TICKS;
typedef struct { ee_u8 portable_id; } core_portable;

#define NULL ((void *)0)
#define align_mem(p) ((void *)(((ee_ptr_int)(p) + 3) & ~3ul))
#define HAS_STDIO 0
#define HAS_PRINTF 0
#define HAS_FLOAT 0
#define MULTITHREAD 1
#define CORE_DEBUG 0
#define SEED_METHOD SEED_FUNC
#define portme_sys1() 0
#define portme_sys2() 0
#define portme_sys3() 0x66
#define portme_sys4() 1
#define portme_sys5() 0
#define ee_printf(...) ((void)0)

#endif
