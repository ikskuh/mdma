#include "all.h"
#include "schedule.h"
#include <errno.h>
#include <limits.h>

static const char *const unit_name[] = {
    "ARITH_A", "ARITH_B", "LOGIC_A", "LOGIC_B", "SHIFT_A", "SHIFT_B", "UOP_A", "UOP_B",
    "CMP", "MUL", "MULS", "DIV", "DIVS", "MASK", "BITCNT", "SEL_A", "SEL_B", "PACK",
    "UNPACK", "SWIZZLE8", "MEM_READ", "MEM_WRITE", "STASH_A", "STASH_B", "STASH_C",
    "STASH_D", "STACK_A", "STACK_B", "CPU"
};

static struct Timing {
    int latency, interval;
} timing[UNIT_COUNT];
static int stack_push_ordered, stack_peak;

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
        for (unit = 0; unit < CONTROL && strcmp(name, unit_name[unit]); ++unit)
            ;
        if (unit == CONTROL)
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
    for (int unit = 0; unit < CONTROL; ++unit)
        if (!timing[unit].latency)
            profile_error(path, line + 1, "missing unit ", unit_name[unit]);
}

int
schedule_stack_ordered(void)
{
    return stack_push_ordered;
}

int
schedule_stack_peak(void)
{
    return stack_peak;
}

void
schedule_reset_peak(void)
{
    stack_peak = 0;
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
    int count, fifo_flow;
    unsigned short edge[NODES][NODES];
    int when[NODES], bundle_count;
    int live_out[4][SCHED_STASH];
    int saved[8];
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
storage_conflict(const Schedule *s, const Uses *uses, int node, enum SchedUnit bank)
{
    for (int i = uses[node].first; i <= s->count && i <= uses[node].last; ++i) {
        const SchedNode *use = &s->node[i];
        int reads = 0, conflict = use->unit == bank && i != uses[node].last;
        for (int n = 0; n < use->count; ++n) {
            int operand = use->move[n].value.node;
            if (operand == node)
                reads = 1;
            else if (operand && s->node[operand].unit == bank)
                conflict = 1;
        }
        if (reads && conflict)
            return 1;
    }
    return 0;
}

static int
storage_bank(Schedule *s, Uses *uses, int node, int prefer_stack)
{
    int order[] = {STASH_A, STASH_B, STASH_C, STASH_D, STACK_A};
    if (prefer_stack) {
        order[0] = STACK_A;
        for (int i = 1; i < 5; ++i)
            order[i] = STASH_A + i - 1;
    }
    int selected = -1, best = 8;
    for (int i = 0; i < 5; ++i) {
        enum SchedUnit bank = order[i];
        int active = 0;
        if (bank == STACK_A && (uses[node].count > 1 ||
                               (s->saved[0] && s->saved[0] <= uses[node].last)))
            continue;
        if (s->node[node].move[0].value.node &&
            s->node[s->node[node].move[0].value.node].unit == bank)
            continue;
        if (!s->fifo_flow && bank < STACK_A && s->live_out[bank - STASH_A][0] &&
            s->live_out[bank - STASH_A][0] <= uses[node].last)
            continue;
        if (s->fifo_flow && storage_conflict(s, uses, node, bank))
            continue;
        for (int old = 1; old < node; ++old) {
            if (s->node[old].unit != bank || uses[old].last < node)
                continue;
            ++active;
            if (bank < STACK_A && s->fifo_flow)
                continue;
            if (uses[old].last == node || uses[old].count > 1 || uses[node].count > 1 ||
                (bank < STACK_A && uses[old].last >= uses[node].first) ||
                (bank >= STACK_A && (!stack_push_ordered || uses[old].first <= uses[node].last))) {
                active = 8;
                break;
            }
        }
        if (active < (bank < STACK_A ? SCHED_STASH : 8)) {
            if (!s->fifo_flow || !active || (bank == STACK_A && prefer_stack))
                return bank;
            if (active < best) {
                selected = bank;
                best = active;
            }
        }
    }
    return selected;
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
        if (unit >= STASH_A || !input[i].result)
            continue;
        int next = later[unit][0], fourth = later[unit][3];
        /* Materialize outputs with several consumers or whose intended reads
         * would overtake another generation on the same result FIFO. */
        hold[i] = original[i].count > 1 ||
                  (next && original[i].last >= (hold[next] ? next : original[next].first)) ||
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
    for (int bank = 0; bank < 4; ++bank)
        for (int n = 0; n < SCHED_STASH; ++n) {
            int id = map[region->live_out[bank][n]];
            if (id) {
                s->live_out[bank][n] = id;
                record_use(&uses[id], s->count + 1);
            }
        }
    for (int n = 0; n < 8 && region->saved[n]; ++n) {
        int id = map[region->saved[n]];
        s->saved[n] = id;
        record_use(&uses[id], s->count + 1);
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
        if (previous != i)
            dependency(s, previous, i, !previous || unit >= STASH_A ? 1 :
                       timing[s->node[previous].unit].interval);
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
        if (!s->node[i].count)
            continue;
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

typedef struct {
    int count, id[8], ready[8];
} Queue;

static void
queue_pop(Queue *q)
{
    --q->count;
    memmove(q->id, q->id + 1, q->count * sizeof *q->id);
    memmove(q->ready, q->ready + 1, q->count * sizeof *q->ready);
}

static int
queue_clock(int *words, int *cycles, int ready)
{
    int start = *cycles > ready ? *cycles : ready;
    ++*words;
    *cycles = start + 1;
    return start;
}

static int
select_head(FILE *out, int bank, Queue *q, int id, int *words, int *cycles)
{
    int at = 0;
    while (at < q->count && q->id[at] != id)
        ++at;
    if (at == q->count)
        return 0;
    while (at--) {
        int old = q->id[0], ready = q->ready[0];
        queue_pop(q);
        q->id[q->count] = old;
        q->ready[q->count++] = queue_clock(words, cycles, ready) + timing[bank].latency;
        if (out)
            fprintf(out, "%s.OUT -> %s.IN [sync]\n", unit_name[bank], unit_name[bank]);
    }
    return 1;
}

static int
restore_order(FILE *out, int bank, Queue *q, const int *want, int have_saved, int *words, int *cycles)
{
    int count = 0;
    while (count < SCHED_STASH && want[count])
        ++count;
    if (q->count != count)
        return 0;
    if (!memcmp(q->id, want, count * sizeof *want))
        return 1;
    if (have_saved)
        return 0;
    if (out && stack_peak == 0)
        stack_peak = 1;
    /* Extract each desired head in turn and append it without disturbing the
     * other entries. One balanced push/pop on STACK_A holds the extracted word. */
    for (int n = 0; n < count; ++n) {
        int first = q->id[0];
        if (!select_head(out, bank, q, want[n], words, cycles))
            return 0;
        int saved = queue_clock(words, cycles, q->ready[0]) + timing[STACK_A].latency;
        queue_pop(q);
        if (out)
            fprintf(out, "%s.OUT -> STACK_A.PUSH\n", unit_name[bank]);
        if (first != want[n] && !select_head(out, bank, q, first, words, cycles))
            return 0;
        q->id[q->count] = want[n];
        q->ready[q->count++] = queue_clock(words, cycles, saved) + timing[bank].latency;
        if (out)
            fprintf(out, "STACK_A.TOP -> %s.IN\n", unit_name[bank]);
    }
    return !memcmp(q->id, want, count * sizeof *want);
}

static void
print_bundle(FILE *out, const Schedule *s, const Bundle *b)
{
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

static int
verify(FILE *out, const Schedule *s, int *words, int *cycles)
{
    Queue fifo[UNIT_COUNT] = {{0}};
    int service[UNIT_COUNT] = {0};
    *words = *cycles = 0;
    for (int i = 1; i <= s->count && !s->node[i].count; ++i) {
        int bank = s->node[i].unit;
        if (fifo[bank].count == 8)
            return 0;
        fifo[bank].id[fifo[bank].count++] = i;
    }
    for (int i = 0; i < s->bundle_count; ++i) {
        const Bundle *b = &s->bundle[i];
        int read[UNIT_COUNT] = {0};
        int next = *cycles;
        for (int j = 0; j < b->count; ++j) {
            int src = b->move[j].source;
            if (!src)
                continue;
            int bank = s->node[src].unit;
            Queue *q = &fifo[bank];
            if (!q->count)
                return 0;
            if (read[bank] && read[bank] != src)
                return 0;
            if (bank >= STASH_A && bank < STACK_A && !read[bank] &&
                !select_head(out, bank, q, src, words, cycles))
                return 0;
            int head = bank >= STACK_A ? q->count - 1 : 0;
            if (q->id[head] != src)
                return 0;
            read[bank] = src;
            if (next < q->ready[head])
                next = q->ready[head];
        }
        if (next < *cycles)
            next = *cycles;
        /* Check capacity before popping. A full queue cannot be assumed to
         * accept a simultaneous replacement on every implementation. */
        for (int j = 0; j < b->nwrites; ++j) {
            int bank = s->node[b->writes[j]].unit;
            int capacity = bank >= STACK_A && !stack_push_ordered ? 1 :
                           bank < STASH_A ? 4 : bank < STACK_A ? SCHED_STASH : 8;
            if (fifo[bank].count >= capacity)
                return 0;
        }
        for (int bank = 0; bank < UNIT_COUNT; ++bank) {
            Queue *q = &fifo[bank];
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
                Queue *q = &fifo[m.sink_unit];
                if (q->count == SCHED_STASH)
                    return 0;
                q->id[q->count] = m.source;
                q->ready[q->count++] = next + timing[m.sink_unit].latency;
            }
        }
        for (int j = 0; j < b->nwrites; ++j) {
            int id = b->writes[j], unit = s->node[id].unit;
            Queue *q = &fifo[unit];
            int r = resource(unit);
            int start = next < service[r] ? service[r] : next;
            q->id[q->count] = id;
            q->ready[q->count++] = start + timing[unit].latency;
            if (out && unit == STACK_A && stack_peak < q->count)
                stack_peak = q->count;
            service[r] = start + timing[unit].interval;
        }
        if (b->write_mem) {
            int start = next < service[MEM_READ] ? service[MEM_READ] : next;
            service[MEM_READ] = start + timing[MEM_WRITE].interval;
        }
        if (out)
            print_bundle(out, s, b);
        *words += bundle_words(b);
        *cycles = next + 1;
    }
    Queue *saved = &fifo[STACK_A];
    int count = 0;
    while (count < 8 && s->saved[count])
        ++count;
    if (saved->count != count || memcmp(saved->id, s->saved, count * sizeof *s->saved))
        return 0;
    for (int bank = 0; bank < UNIT_COUNT; ++bank) {
        Queue *q = &fifo[bank];
        if (bank >= STASH_A && bank < STACK_A) {
            if (!restore_order(out, bank, q, s->live_out[bank - STASH_A], count, words, cycles))
                return 0;
        } else if (bank != STACK_A && q->count)
            return 0;
    }
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
    s->fifo_flow = region->fifo_flow;
    int expanded = expand(s, region, uses);
    int ok = expanded && build_graph(s, uses) && latest_first(s, uses);
    if (ok) {
        qsort(s->bundle, s->bundle_count, sizeof *s->bundle, bundle_order);
        ok = verify(NULL, s, &words, &cycles);
    }
    if (!ok && expanded && baseline_cycles < 0) {
        /* Replay one complete group per bundle before giving up a home. */
        s->bundle_count = 0;
        ok = 1;
        for (int i = 1; ok && i <= s->count; ++i)
            if (s->node[i].count) {
                Bundle *b = &s->bundle[s->bundle_count++];
                *b = (Bundle){0};
                ok = pack(b, s, uses, i);
            }
        ok = ok && verify(NULL, s, &words, &cycles);
    }
    ok = ok && (baseline_cycles < 0 || cycles < baseline_cycles ||
                (cycles == baseline_cycles && words < baseline_words));
    if (ok)
        ok = verify(out, s, &words, &cycles);
    free(s);
    return ok;
}
