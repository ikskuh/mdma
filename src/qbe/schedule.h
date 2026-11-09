#ifndef MDMA_SCHEDULE_H
#define MDMA_SCHEDULE_H

enum SchedUnit {
    ARITH_A, ARITH_B, LOGIC_A, LOGIC_B, SHIFT_A, SHIFT_B, UOP_A, UOP_B, CMP, MUL, MULS, DIV, DIVS,
    MASK, BITCNT, SEL_A, SEL_B, PACK, UNPACK, SWIZZLE8,
    MEM_READ, MEM_WRITE, STASH_A, STASH_B, STASH_C, STASH_D, STACK_A, STACK_B,
    CONTROL, UNIT_COUNT, HOLD = UNIT_COUNT
};

typedef struct {
    int node;
    const char *port; /* Override the producer's result port for sibling outputs. */
    const char *imm;
} SchedValue;

typedef struct {
    const char *sink;
    SchedValue value;
} SchedMove;

typedef struct {
    enum SchedUnit unit;
    const char *result;
    int count;
    SchedMove move[5];
} SchedNode;

/* Bound work on large basic blocks by lowering a sequence of smaller regions. */
enum { SCHED_NODES = 192, SCHED_REGION = 24, SCHED_STASH = 7 };

typedef struct {
    int count, fifo_flow;
    SchedNode node[SCHED_NODES];
    int live_out[4][SCHED_STASH];
    int saved[8]; /* STACK_A values retained across a call, in push order. */ /* Retain the given node in each STASH at region exit. */
} SchedRegion;

void schedule_profile(const char *path);
int schedule_serial_read_wait(void);
int schedule_stack_ordered(void);
int schedule_stack_peak(void);
void schedule_reset_peak(void);
int schedule_emit(FILE *out, const SchedRegion *region, int baseline_words, int baseline_cycles);

#endif
