#include "all.h"
#include "schedule.h"
#include <errno.h>
#include <limits.h>

static const char *const unit_name[] = {
    "ARITH_A", "ARITH_B", "LOGIC_A", "LOGIC_B", "SHIFT_A", "SHIFT_B", "UOP_A", "UOP_B",
    "CMP", "MUL", "MULS", "DIV", "DIVS", "MASK", "BITCNT", "SEL_A", "SEL_B", "PACK",
    "UNPACK", "SWIZZLE8", "MEM_READ", "MEM_WRITE", "STASH_A", "STASH_B", "STASH_C",
    "STASH_D", "STACK_A", "STACK_B"
};

static struct Timing {
    int latency, interval;
} timing[UNIT_COUNT];
static int stack_push_ordered;

static void
profile_error(const char *path, int line, const char *message, const char *name)
{
    fprintf(stderr, "qbe-mdma: %s:%d: %s%s\n", path, line, message, name);
    exit(1);
}

static int
clocks(const char *value)
{
    char *end;
    errno = 0;
    long n = strtol(value, &end, 10);
    return errno || end == value || *end || n < 1 || n > 10000 ? 0 : (int)n;
}

void
schedule_profile(const char *path)
{
    static char default_profile[] =
#include "mdma_default_profile.h"
        ;
    FILE *file = path ? fopen(path, "r") :
                       fmemopen(default_profile, sizeof default_profile - 1, "r");
    if (!path)
        path = "embedded ECP5 profile";
    if (!file)
        profile_error(path, 0, "cannot open profile: ", strerror(errno));
    char *row = NULL;
    size_t capacity = 0;
    int line = 0, seen_stack = 0;
    while (getline(&row, &capacity, file) >= 0) {
        ++line;
        char *comment = strchr(row, '#');
        if (comment)
            *comment = 0;
        const char *ws = " \t\r\n";
        char *name = strtok(row, ws);
        if (!name)
            continue;
        char *first = strtok(NULL, ws);
        char *second = strtok(NULL, ws);
        if (!strcmp(name, "stack_push_ordered")) {
            if (seen_stack++ || !first || second || (strcmp(first, "yes") && strcmp(first, "no")))
                profile_error(path, line, "expected one stack_push_ordered yes/no entry", "");
            stack_push_ordered = !strcmp(first, "yes");
            continue;
        }
        int unit;
        for (unit = 0; unit < UNIT_COUNT && strcmp(name, unit_name[unit]); ++unit)
            ;
        if (unit == UNIT_COUNT)
            profile_error(path, line, "unknown unit ", name);
        if (timing[unit].latency)
            profile_error(path, line, "duplicate unit ", name);
        if (!first || !second || strtok(NULL, ws) || !clocks(first) || !clocks(second))
            profile_error(path, line, "expected UNIT LATENCY ISSUE_INTERVAL for ", name);
        timing[unit] = (struct Timing){clocks(first), clocks(second)};
    }
    if (ferror(file))
        profile_error(path, line, "cannot read profile", "");
    free(row);
    fclose(file);
    for (int unit = 0; unit < UNIT_COUNT; ++unit)
        if (!timing[unit].latency)
            profile_error(path, line + 1, "missing unit ", unit_name[unit]);
}

/* Internal node IDs are one-based. Node zero is reserved for immediates. */
enum { NODES = 2 * SCHED_NODES + 1 };
typedef struct {
    int first, last, count;
} Uses;

typedef struct {
    int time, count, sync, write_mem;
    struct Transfer {
        int sink_unit, source;
        const char *sink, *port, *imm;
    } move[5];
    int writes[5], nwrites;
    const char *imm;
} Bundle;

typedef struct {
    SchedNode node[NODES];
    int count;
    unsigned short edge[NODES][NODES];
    int when[NODES], bundle_count;
    Bundle bundle[NODES];
} Schedule;

static int
resource(int unit)
{
    return unit == MEM_WRITE ? MEM_READ : unit;
}

static const char *
hardware_name(int unit)
{
    return unit == MEM_READ || unit == MEM_WRITE ? "MEM" : unit_name[unit];
}

static void
dependency(Schedule *s, int from, int to, int gap)
{
    assert(from < to);
    if (from && s->edge[from][to] < gap + 1)
        s->edge[from][to] = gap + 1;
}

static void
choose_units(SchedNode *nodes, int count)
{
    int ready[SCHED_NODES + 1] = {0};
    int next[UNIT_COUNT] = {0};
    for (int i = 1; i <= count; ++i) {
        SchedNode *n = &nodes[i];
        int start = 0;
        for (int j = 0; j < n->count; ++j) {
            int operand = n->move[j].value.node;
            if (start < ready[operand])
                start = ready[operand];
        }
        int unit = n->unit;
        if (unit == HOLD) {
            ready[i] = start + 1;
            continue;
        }
        if (unit == ARITH_A || unit == LOGIC_A || unit == SHIFT_A || unit == UOP_A) {
            int a = start > next[unit] ? start : next[unit];
            int b = start > next[unit + 1] ? start : next[unit + 1];
            if (b + timing[unit + 1].latency < a + timing[unit].latency)
                ++unit;
        }
        n->unit = unit;
        int r = resource(unit);
        if (start < next[r])
            start = next[r];
        ready[i] = start + timing[unit].latency;
        next[r] = start + timing[unit].interval;
    }
}

static int
storage_bank(Schedule *s, Uses *uses, int node, int prefer_stack)
{
    int order[] = {STASH_A, STASH_B, STASH_C, STASH_D, STACK_A, STACK_B};
    if (prefer_stack) {
        order[0] = STACK_A;
        order[1] = STACK_B;
        for (int i = 2; i < 6; ++i)
            order[i] = STASH_A + i - 2;
    }
    for (int i = 0; i < 6; ++i) {
        enum SchedUnit bank = order[i];
        int active = 0;
        if (bank >= STACK_A && uses[node].count > 1)
            continue;
        for (int old = 1; old < node; ++old) {
            if (s->node[old].unit != bank || uses[old].last < node)
                continue;
            ++active;
            if (uses[old].last == node || uses[old].count > 1 || uses[node].count > 1 ||
                (bank < STACK_A && uses[old].last >= uses[node].first) ||
                (bank >= STACK_A && (!stack_push_ordered || uses[old].first <= uses[node].last))) {
                active = 8;
                break;
            }
        }
        if (active < 8)
            return bank;
    }
    return -1;
}

static void
record_use(Uses *use, int at)
{
    if (!use->count)
        use->first = at;
    if (use->last != at)
        ++use->count;
    use->last = at;
}

static int
expand(Schedule *s, const SchedRegion *region, Uses *uses)
{
    SchedNode input[SCHED_NODES + 1];
    Uses original[SCHED_NODES + 1] = {{0}};
    int map[SCHED_NODES + 1] = {0}, hold[SCHED_NODES + 1] = {0};
    memcpy(input + 1, region->node, region->count * sizeof *input);
    choose_units(input, region->count);
    for (int i = 1; i <= region->count; ++i)
        for (int j = 0; j < input[i].count; ++j) {
            int src = input[i].move[j].value.node;
            if (src)
                record_use(&original[src], i);
        }

    int later[UNIT_COUNT][4] = {{0}};
    for (int i = region->count; i > 0; --i) {
        int unit = input[i].unit;
        if (unit == HOLD || !input[i].result)
            continue;
        int next = later[unit][0], fourth = later[unit][3];
        /* Materialize outputs with several consumers or whose intended reads
         * would overtake another generation on the same result FIFO. */
        hold[i] = original[i].count > 1 ||
                  (next && original[i].last >= original[next].first) ||
                  (fourth && original[i].last >= fourth);
        if (hold[i] && !strcmp(input[i].result, "ADDR") && unit == PACK)
            return 0; /* PACK's siblings are only used together by a store. */
        for (int j = 3; j > 0; --j)
            later[unit][j] = later[unit][j - 1];
        later[unit][0] = i;
    }
    for (int i = 1; i <= region->count; ++i) {
        int at = ++s->count;
        s->node[at] = input[i];
        for (int j = 0; j < input[i].count; ++j) {
            SchedValue *v = &s->node[at].move[j].value;
            if (v->node) {
                int src = v->node;
                v->node = map[src];
                if (hold[src])
                    v->port = NULL;
                record_use(&uses[v->node], at);
            }
        }
        map[i] = at;
        if (hold[i]) {
            map[i] = ++s->count;
            s->node[s->count] = (SchedNode){
                .unit = HOLD, .count = 1, .move = {{NULL, {at, NULL, NULL}}}
            };
            record_use(&uses[at], s->count);
        }
    }
    for (int i = 1; i <= s->count; ++i) {
        SchedNode *n = &s->node[i];
        if (n->unit != HOLD)
            continue;
        int bank = storage_bank(s, uses, i, uses[i].last - i > 2);
        if (bank < 0)
            return 0;
        n->unit = bank;
        n->result = bank < STACK_A ? "OUT" : "TOP";
        n->move[0].sink = bank < STACK_A ? "IN" : "PUSH";
    }
    return 1;
}

static int
build_graph(Schedule *s, const Uses *uses)
{
    int last[UNIT_COUNT] = {0}, pop[UNIT_COUNT] = {0}, history[UNIT_COUNT][4] = {{0}};
    for (int i = 1; i <= s->count; ++i) {
        const SchedNode *n = &s->node[i];
        int unit = n->unit, r = resource(unit);
        int seen[5], nseen = 0;
        for (int j = 0; j < n->count; ++j) {
            int src = n->move[j].value.node;
            if (!src)
                continue;
            int k;
            for (k = 0; k < nseen && seen[k] != src; ++k)
                ;
            if (k != nseen)
                continue;
            seen[nseen++] = src;
            int bank = s->node[src].unit;
            int previous = bank >= STASH_A ? last[bank] : 0;
            if (bank >= STASH_A) {
                if (previous == i)
                    return 0;
                dependency(s, previous, i, 1);
                last[bank] = i;
            }
            dependency(s, src, i, timing[bank].latency);
        }
        int previous = last[r];
        dependency(s, previous, i, !previous || unit >= STASH_A ? 1 : timing[s->node[previous].unit].interval);
        last[r] = i;
        if (unit >= STASH_A || !n->result)
            continue;
        if (!uses[i].count || pop[unit] >= uses[i].first || history[unit][3] >= i)
            return 0;
        dependency(s, pop[unit], uses[i].first, 1);
        pop[unit] = uses[i].last;
        dependency(s, history[unit][3], i, 1);
        for (int k = 3; k > 0; --k)
            history[unit][k] = history[unit][k - 1];
        history[unit][0] = uses[i].last;
    }
    return 1;
}

static int
add_move(Bundle *b, struct Transfer m)
{
    if (b->count == 5)
        return 0;
    for (int j = 0; j < b->count; ++j) {
        struct Transfer old = b->move[j];
        if (old.sink_unit == m.sink_unit && !strcmp(old.sink, m.sink))
            return 0;
        if (m.source && old.source == m.source)
            b->sync = 1;
    }
    if (m.imm && b->imm && strcmp(m.imm, b->imm))
        return 0;
    if (m.imm)
        b->imm = m.imm;
    b->move[b->count++] = m;
    return 1;
}

static int
pack(Bundle *b, const Schedule *s, const Uses *uses, int at)
{
    const SchedNode *n = &s->node[at];
    int unit = resource(n->unit), seen[5], nseen = 0;
    if (n->unit == MEM_WRITE)
        b->sync = b->write_mem = 1;
    for (int j = 0; j < n->count; ++j) {
        SchedMove m = n->move[j];
        int src = m.value.node;
        if (!add_move(b, (struct Transfer){unit, src, m.sink, m.value.port, m.value.imm}))
            return 0;
        if (!src || s->node[src].unit < STASH_A || uses[src].last == at)
            continue;
        int k;
        for (k = 0; k < nseen && seen[k] != src; ++k)
            ;
        if (k != nseen)
            continue;
        seen[nseen++] = src;
        if (!add_move(b, (struct Transfer){s->node[src].unit, src, "IN", NULL, NULL}))
            return 0;
    }
    if (n->result)
        b->writes[b->nwrites++] = at;
    return 1;
}

static int
latest_first(Schedule *s, const Uses *uses)
{
    for (int i = s->count; i > 0; --i) {
        int latest = 0;
        for (int j = i + 1; j <= s->count; ++j)
            if (s->edge[i][j] && latest > s->when[j] - s->edge[i][j] + 1)
                latest = s->when[j] - s->edge[i][j] + 1;
        for (;;) {
            int slot = 0;
            while (slot < s->bundle_count && s->bundle[slot].time != latest)
                ++slot;
            Bundle next = s->bundle[slot];
            next.time = latest;
            if (pack(&next, s, uses, i)) {
                s->bundle[slot] = next;
                if (slot == s->bundle_count)
                    ++s->bundle_count;
                s->when[i] = latest;
                break;
            }
            if (slot == s->bundle_count)
                return 0;
            --latest;
        }
    }
    return 1;
}

static int
bundle_order(const void *a, const void *b)
{
    return ((const Bundle *)a)->time - ((const Bundle *)b)->time;
}

static int
bundle_words(const Bundle *b)
{
    if (!b->imm || !strcmp(b->imm, "0x1"))
        return 1;
    if (b->count <= 4) {
        char *end;
        unsigned long long n = strtoull(b->imm, &end, 0);
        if (!*end && (n <= 4095 || n >= UINT64_MAX - 2047))
            return 1;
    }
    return 2;
}

static int
verify(const Schedule *s, int *words, int *cycles)
{
    struct Queue { int count, id[8], ready[8]; } fifo[UNIT_COUNT] = {{0}};
    int service[UNIT_COUNT] = {0};
    *words = *cycles = 0;
    for (int i = 0; i < s->bundle_count; ++i) {
        const Bundle *b = &s->bundle[i];
        int read[UNIT_COUNT] = {0};
        int next = *cycles;
        for (int j = 0; j < b->count; ++j) {
            int src = b->move[j].source;
            if (!src)
                continue;
            int bank = s->node[src].unit;
            struct Queue *q = &fifo[bank];
            if (!q->count)
                return 0;
            int head = bank >= STACK_A ? q->count - 1 : 0;
            if (q->id[head] != src)
                return 0;
            read[bank] = src;
            if (next < q->ready[head])
                next = q->ready[head];
        }
        /* Check capacity before popping. A full queue cannot be assumed to
         * accept a simultaneous replacement on every implementation. */
        for (int j = 0; j < b->nwrites; ++j) {
            int bank = s->node[b->writes[j]].unit;
            int capacity = bank >= STACK_A && !stack_push_ordered ? 1 :
                           bank >= STASH_A ? 8 : 4;
            if (fifo[bank].count >= capacity)
                return 0;
        }
        for (int bank = 0; bank < UNIT_COUNT; ++bank) {
            struct Queue *q = &fifo[bank];
            if (!read[bank])
                continue;
            --q->count;
            if (bank < STACK_A) {
                memmove(q->id, q->id + 1, q->count * sizeof *q->id);
                memmove(q->ready, q->ready + 1, q->count * sizeof *q->ready);
            }
        }
        for (int j = 0; j < b->count; ++j) {
            struct Transfer m = b->move[j];
            if (m.sink_unit >= STASH_A && read[m.sink_unit] && m.source == read[m.sink_unit]) {
                struct Queue *q = &fifo[m.sink_unit];
                if (q->count)
                    return 0;
                q->id[0] = m.source;
                q->ready[0] = next + timing[m.sink_unit].latency;
                q->count = 1;
            }
        }
        for (int j = 0; j < b->nwrites; ++j) {
            int id = b->writes[j], unit = s->node[id].unit;
            struct Queue *q = &fifo[unit];
            int r = resource(unit);
            int start = next < service[r] ? service[r] : next;
            q->id[q->count] = id;
            q->ready[q->count++] = start + timing[unit].latency;
            service[r] = start + timing[unit].interval;
        }
        if (b->write_mem) {
            int start = next < service[MEM_READ] ? service[MEM_READ] : next;
            service[MEM_READ] = start + timing[MEM_WRITE].interval;
        }
        *words += bundle_words(b);
        *cycles = next + 1;
    }
    for (int bank = 0; bank < UNIT_COUNT; ++bank)
        if (fifo[bank].count)
            return 0;
    return 1;
}

int
schedule_serial_read_wait(void)
{
    /* The old templates consume MEM.CHUNK one or two moves after issuing. */
    return timing[MEM_READ].latency > 2 ? timing[MEM_READ].latency - 2 : 0;
}

int
schedule_emit(FILE *out, const SchedRegion *region, int baseline_words, int baseline_cycles)
{
    if (!region->count)
        return 1;
    Schedule *s = emalloc(sizeof *s);
    Uses uses[NODES] = {{0}};
    int words, cycles;
    int ok = expand(s, region, uses) && build_graph(s, uses) && latest_first(s, uses);
    if (ok) {
        qsort(s->bundle, s->bundle_count, sizeof *s->bundle, bundle_order);
        ok = verify(s, &words, &cycles) &&
             (cycles < baseline_cycles || (cycles == baseline_cycles && words < baseline_words));
    }
    if (ok)
        for (int i = 0; i < s->bundle_count; ++i) {
            const Bundle *b = &s->bundle[i];
            for (int j = 0; j < b->count; ++j) {
                struct Transfer m = b->move[j];
                if (j)
                    fputs(", ", out);
                if (m.source) {
                    const SchedNode *src = &s->node[m.source];
                    fprintf(out, "%s.%s", hardware_name(src->unit), m.port ? m.port : src->result);
                } else
                    fputs(m.imm ? "CONST" : "ZERO", out);
                fprintf(out, " -> %s.%s", hardware_name(m.sink_unit), m.sink);
            }
            if (b->sync || b->imm) {
                fputs(b->sync ? " [sync" : " [", out);
                if (b->imm)
                    fprintf(out, "%simm=%s", b->sync ? ", " : "", b->imm);
                fputc(']', out);
            }
            fputc('\n', out);
        }
    free(s);
    return ok;
}
