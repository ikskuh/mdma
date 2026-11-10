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
    int count, pinned;
    SchedMove move[5];
} SchedNode;

/* Bound work on large basic blocks by lowering a sequence of smaller regions. */
enum { SCHED_NODES = 192, SCHED_REGION = 24, SCHED_STASH = 7 };

typedef struct {
    enum { TERM_NONE, TERM_JUMP, TERM_PRED, TERM_CALL, TERM_RETURN } kind;
    const char *target;
} SchedTerm;

typedef struct {
    int count, fifo_flow;
    SchedNode node[SCHED_NODES];
    int live_out[4][SCHED_STASH]; /* STASH contents in FIFO order at region exit. */
    int result_out[STASH_A]; /* At most one retained result per compute FU. */
    int saved[8]; /* STACK_A values retained across a call, in push order. */
    SchedTerm term;
} SchedRegion;

void schedule_profile(const char *path);
int schedule_serial_read_wait(void);
int schedule_stack_peak(void);
void schedule_reset_peak(void);
int schedule_emit(FILE *out, const SchedRegion *region, int baseline_words, int baseline_cycles);

int schedule_countdown(FILE *out, const char *entry, const char *loop, uint32_t seed, int seed_arg);

#endif
