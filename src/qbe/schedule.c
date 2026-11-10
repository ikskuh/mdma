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
    int time, count, sync, write_mem, pred;
    struct Transfer {
        int sink_unit, source;
        const char *sink, *port, *imm, *fixed;
        int recirculate, last_read;
    } move[5];
    int writes[5], nwrites;
    const char *imm;
} Bundle;

typedef struct {
    SchedNode node[NODES];
    int count, fifo_flow;
    unsigned short edge[NODES][NODES];
    int when[NODES], group[NODES], bundle_count;
    int live_out[4][SCHED_STASH];
    int saved[8], result_out[STASH_A];
    Bundle bundle[NODES];
    SchedTerm term;
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
    assert(from != to);
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
        if (!n->pinned && (unit == ARITH_A || unit == LOGIC_A || unit == SHIFT_A || unit == UOP_A)) {
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

/* Try one retirement bundle for the uses of a generation. The graph
 * and bundle verifier will reject a merge that cannot issue together. */
static int
join_consumers(const SchedNode *nodes, int count, int source, int *groups)
{
    int members[5], moves = 0, n = 0;
    const char *imm = NULL;
    for (int i = source + 1; i <= count; ++i) {
        const SchedNode *node = &nodes[i];
        int uses = 0;
        for (int j = 0; j < node->count; ++j)
            uses |= node->move[j].value.node == source;
        if (!uses)
            continue;
        if (groups[i] != i || node->unit == HOLD || node->unit == MEM_READ ||
            node->unit == MEM_WRITE || moves + node->count > 5)
            return 0;
        for (int j = 0; j < node->count; ++j) {
            const char *arg = node->move[j].value.imm;
            if (arg && imm && strcmp(imm, arg))
                return 0;
            if (arg)
                imm = arg;
        }
        moves += node->count;
        members[n++] = i;
    }
    if (n < 2)
        return 0;
    for (int i = 1; i < n; ++i)
        groups[members[i]] = members[0];
    return 1;
}

static void
unpack_masks(SchedNode *nodes, int count)
{
    for (int i = 1; i <= count; ++i) {
        SchedNode *node = &nodes[i];
        if (node->pinned || node->unit != LOGIC_A || node->count != 2 || strcmp(node->result, "AND"))
            continue;
        const char *mask = node->move[1].value.imm;
        const char *type = mask && !strcmp(mask, "0xffffffff") ? "0x4" :
                           mask && !strcmp(mask, "0xffff") ? "0x2" : NULL;
        /* The alternate UNPACK request also needs an immediate. */
        if (!type || node->move[0].value.imm)
            continue;
        SchedValue word = node->move[0].value;
        *node = (SchedNode){.unit = UNPACK, .result = "VALUE", .count = 3,
                            .move = {{"CHUNK", word}, {"ADDR", {0}}, {"TYPE", {.imm = type}}}};
    }
}

static int
expand(Schedule *s, const SchedRegion *region, Uses *uses, int reorder, int fanout, int unpack)
{
    SchedNode input[SCHED_NODES + 1];
    Uses original[SCHED_NODES + 1] = {{0}};
    int map[SCHED_NODES + 1] = {0}, hold[SCHED_NODES + 1] = {0};
    int launch[SCHED_NODES + 1] = {0};
    int groups[SCHED_NODES + 1], shared[SCHED_NODES + 1] = {0};
    memcpy(input + 1, region->node, region->count * sizeof *input);
    if (unpack)
        unpack_masks(input, region->count);
    choose_units(input, region->count);
    for (int i = 1; i <= region->count; ++i)
        groups[i] = i;
    for (int i = 1; i <= region->count; ++i)
        for (int j = 0; j < input[i].count; ++j) {
            int src = input[i].move[j].value.node;
            if (src)
                record_use(&original[src], i);
        }

    if (fanout)
        for (int i = 1; i <= region->count; ++i)
            if (input[i].unit < STASH_A && original[i].count > 1)
                shared[i] = join_consumers(input, region->count, i, groups);
    int later[UNIT_COUNT][4] = {{0}};
    for (int i = region->count; i > 0; --i) {
        int unit = input[i].unit;
        if (unit >= STASH_A || !input[i].result)
            continue;
        int next = later[unit][0], fourth = later[unit][3];
        /* Materialize outputs with several consumers or whose intended reads
         * would overtake another generation on the same result FIFO. */
        int next_pop = next ? (hold[next] ? next : original[next].first) : 0;
        hold[i] = (original[i].count > 1 && !shared[i]) ||
                  (next && (original[i].last == next_pop ||
                            (!reorder && original[i].last > next_pop))) ||
                  (!reorder && fourth && original[i].last >= fourth);
        if (hold[i] && (!input[i].count || (!strcmp(input[i].result, "ADDR") && unit == PACK)))
            return 0; /* PACK's siblings are only used together by a store. */
        for (int j = 3; j > 0; --j)
            later[unit][j] = later[unit][j - 1];
        later[unit][0] = i;
    }
    for (int i = 1; i <= region->count; ++i) {
        int at = ++s->count;
        s->node[at] = input[i];
        /* The leader is the first consumer, so it has already been mapped. */
        launch[i] = at;
        s->group[at] = launch[groups[i]];
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
            s->group[s->count] = s->count;
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
    for (int bank = 0; bank < STASH_A; ++bank)
        if (region->result_out[bank]) {
            int id = map[region->result_out[bank]];
            if (s->node[id].unit != (enum SchedUnit)bank)
                return 0;
            s->result_out[bank] = id;
            record_use(&uses[id], s->count + 1);
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
build_graph(Schedule *s, const Uses *uses, int reorder)
{
    int last[UNIT_COUNT] = {0}, last_read[UNIT_COUNT] = {0}, pop[UNIT_COUNT] = {0}, history[UNIT_COUNT][4] = {{0}};
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
                dependency(s, previous, i, last_read[bank] == src ||
                           (!last_read[bank] && src < previous) ? 0 : 1);
                last[bank] = i;
                last_read[bank] = src;
            }
            dependency(s, src, i, timing[bank].latency);
        }
        int previous = last[r];
        if (previous != i)
            dependency(s, previous, i,
                       unit >= STASH_A && unit < STACK_A && last_read[r] &&
                       uses[last_read[r]].last == previous ? 0 :
                       !previous || unit >= STASH_A ? 1 : timing[s->node[previous].unit].interval);
        last[r] = i;
        last_read[r] = 0;
        if (unit >= STASH_A || !n->result)
            continue;
        if (!uses[i].count || pop[unit] > s->count || pop[unit] == uses[i].first || history[unit][3] == i ||
            (!reorder && (pop[unit] > uses[i].first || history[unit][3] > i)))
            return 0;
        if (uses[i].first <= s->count)
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
    for (int j = 0; j < b->count; ++j) {
        struct Transfer old = b->move[j];
        if (m.source && old.source == m.source) {
            if (m.recirculate && (old.recirculate || old.last_read))
                return 1;
            if (m.last_read && old.recirculate) {
                --b->count;
                memmove(&b->move[j], &b->move[j + 1], (b->count - j) * sizeof *b->move);
                --j;
                continue;
            }
            b->sync = 1;
        }
        if (old.sink_unit == m.sink_unit && !strcmp(old.sink, m.sink))
            return 0;
    }
    if (b->count == 5)
        return 0;
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
        int condition = !strcmp(m.sink, "CPU.COND");
        struct Transfer move = {.sink_unit = condition ? CONTROL : unit, .source = src,
                                .sink = condition ? "COND" : m.sink, .port = m.value.port,
                                .imm = m.value.imm, .last_read = src && uses[src].last == at};
        if (!add_move(b, move))
            return 0;
        if (!src || s->node[src].unit < STASH_A || uses[src].last == at)
            continue;
        int k;
        for (k = 0; k < nseen && seen[k] != src; ++k)
            ;
        if (k != nseen)
            continue;
        seen[nseen++] = src;
        if (!add_move(b, (struct Transfer){.sink_unit = s->node[src].unit, .source = src,
                                           .sink = "IN", .recirculate = 1}))
            return 0;
    }
    if (n->result)
        b->writes[b->nwrites++] = at;
    return 1;
}

static int
collapse_groups(Schedule *s)
{
    unsigned short (*edge)[NODES] = emalloc(sizeof s->edge);
    int ok = 1;
    for (int i = 1; i <= s->count; ++i)
        for (int j = 1; j <= s->count; ++j) {
            unsigned short gap = s->edge[i][j];
            if (!gap)
                continue;
            int from = s->group[i], to = s->group[j];
            if (from == to)
                ok &= gap == 1;
            else if (edge[from][to] < gap)
                edge[from][to] = gap;
        }
    memcpy(s->edge, edge, sizeof s->edge);
    free(edge);
    return ok;
}

static int
pack_group(Bundle *bundle, const Schedule *s, const Uses *uses, int leader)
{
    for (int i = leader; i <= s->count; ++i)
        if (s->group[i] == leader && !pack(bundle, s, uses, i))
            return 0;
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

/* Rank ready work by the remaining latency on the dependency graph. In the
 * relaxed graph, a FIFO retirement edge may point backward in IL order. */
static int
earliest_first(Schedule *s, const Uses *uses)
{
    int predecessors[NODES] = {0}, order[NODES], count = 0;
    int critical[NODES] = {0}, ready[NODES] = {0}, when[NODES] = {0};
    for (int i = 1; i <= s->count; ++i) {
        if (!s->node[i].count || s->group[i] != i)
            continue;
        for (int j = 1; j <= s->count; ++j)
            if (s->edge[j][i] && s->node[j].count)
                ++predecessors[i];
        if (!predecessors[i])
            order[count++] = i;
    }
    memcpy(when, predecessors, sizeof when);
    for (int n = 0; n < count; ++n)
        for (int j = 1; j <= s->count; ++j)
            if (s->edge[order[n]][j] && --when[j] == 0)
                order[count++] = j;
    for (int i = 1; i <= s->count; ++i)
        if (when[i])
            return 0;
    for (int n = count; n-- > 0;) {
        int i = order[n];
        for (int j = 1; j <= s->count; ++j)
            if (s->edge[i][j] && critical[i] < critical[j] + s->edge[i][j])
                critical[i] = critical[j] + s->edge[i][j];
    }
    int time = 0, placed = 0;
    Bundle bundle = {0};
    while (placed < count) {
        int best = 0, next = INT_MAX;
        Bundle packed = {0};
        for (int i = 1; i <= s->count; ++i) {
            if (!s->node[i].count || s->group[i] != i || predecessors[i] != 0)
                continue;
            if (ready[i] > time) {
                if (ready[i] < next)
                    next = ready[i];
                continue;
            }
            if (best && critical[i] <= critical[best])
                continue;
            Bundle trial = bundle;
            if (pack_group(&trial, s, uses, i)) {
                best = i;
                packed = trial;
            }
        }
        if (!best) {
            if (bundle.count) {
                s->bundle[s->bundle_count++] = bundle;
                bundle = (Bundle){0};
                ++time;
            } else if (next != INT_MAX) {
                time = next;
            } else
                return 0;
            continue;
        }
        bundle = packed;
        predecessors[best] = -1;
        ++placed;
        for (int j = 1; j <= s->count; ++j)
            if (s->edge[best][j]) {
                int earliest = time + s->edge[best][j] - 1;
                if (ready[j] < earliest)
                    ready[j] = earliest;
                --predecessors[j];
            }
    }
    if (bundle.count)
        s->bundle[s->bundle_count++] = bundle;
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

static void
print_bundle(FILE *out, const Schedule *s, const Bundle *b)
{
    for (int j = 0; j < b->count; ++j) {
        struct Transfer m = b->move[j];
        if (j)
            fputs(", ", out);
        if (m.fixed)
            fputs(m.fixed, out);
        else if (m.source) {
            const SchedNode *src = &s->node[m.source];
            fprintf(out, "%s.%s", hardware_name(src->unit), m.port ? m.port : src->result);
        } else
            fputs(m.imm ? "CONST" : "ZERO", out);
        fprintf(out, " -> %s.%s", hardware_name(m.sink_unit), m.sink);
    }
    if (b->sync || b->pred || b->imm) {
        fputs(" [", out);
        if (b->pred)
            fputs(b->sync || b->imm ? "pred, " : "pred", out);
        if (b->sync)
            fputs(b->imm ? "sync, " : "sync", out);
        if (b->imm)
            fprintf(out, "imm=%s", b->imm);
        fputc(']', out);
    }
    fputc('\n', out);
}

typedef struct {
    FILE *out;
    const Schedule *schedule;
    Bundle pending;
    int count;
} Emission;

static void
emit_bundle(Emission *emit, const Bundle *bundle)
{
    if (emit->out && emit->pending.count)
        print_bundle(emit->out, emit->schedule, &emit->pending);
    emit->pending = *bundle;
    ++emit->count;
}

static void
repair(Emission *emit, int source, int sink, const char *port, int sync)
{
    static const char *const heads[] = {
        "STASH_A.OUT", "STASH_B.OUT", "STASH_C.OUT", "STASH_D.OUT", "STACK_A.TOP"
    };
    Bundle b = {.count = 1, .sync = sync,
                .move = {{.sink_unit = sink, .sink = port, .fixed = heads[source - STASH_A]}}};
    emit_bundle(emit, &b);
}

static int
emit_terminal(Emission *emit, int *words, int *cycles)
{
    SchedTerm term = emit->schedule->term;
    if (term.kind != TERM_NONE) {
        Bundle tail = emit->pending;
        struct Transfer jump = {.sink_unit = CONTROL, .sink = "PC", .imm = term.target,
                                .fixed = term.kind == TERM_RETURN ? "STACK_B.TOP" : NULL};
        struct Transfer continuation = {.sink_unit = STACK_B, .sink = "PUSH", .fixed = "PC_NEXT"};
        /* A terminal can share the last bundle of its own path only. Keep
         * memory requests in their original retirement order. */
        int safe = 1;
        for (int i = 0; i < tail.count; ++i)
            if (tail.move[i].sink_unit == MEM_READ)
                safe = 0;
        if (safe && add_move(&tail, jump) &&
            (term.kind != TERM_CALL || add_move(&tail, continuation))) {
            if (term.kind == TERM_PRED && emit->count > 1)
                return 0;
            tail.pred = term.kind == TERM_PRED;
            tail.sync |= term.kind == TERM_CALL;
            *words += bundle_words(&tail) - (emit->pending.count ? bundle_words(&emit->pending) : 0);
            *cycles += !emit->pending.count;
            emit->pending = tail;
        } else {
            if (term.kind == TERM_PRED && emit->count)
                return 0;
            Bundle jump_bundle = {.pred = term.kind == TERM_PRED, .sync = term.kind == TERM_CALL};
            add_move(&jump_bundle, jump);
            if (term.kind == TERM_CALL)
                add_move(&jump_bundle, continuation);
            *words += bundle_words(&jump_bundle);
            ++*cycles;
            emit_bundle(emit, &jump_bundle);
        }
    }
    if (emit->out && emit->pending.count)
        print_bundle(emit->out, emit->schedule, &emit->pending);
    return 1;
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
select_head(Emission *emit, int bank, Queue *q, int id, int *words, int *cycles)
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
        repair(emit, bank, bank, "IN", 1);
    }
    return 1;
}

static int
restore_order(Emission *emit, int bank, Queue *q, const int *want, int have_saved, int *words, int *cycles)
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
    if (emit->out && stack_peak == 0)
        stack_peak = 1;
    /* Extract each desired head in turn and append it without disturbing the
     * other entries. One balanced push/pop on STACK_A holds the extracted word. */
    for (int n = 0; n < count; ++n) {
        int first = q->id[0];
        if (!select_head(emit, bank, q, want[n], words, cycles))
            return 0;
        int saved = queue_clock(words, cycles, q->ready[0]) + timing[STACK_A].latency;
        queue_pop(q);
        repair(emit, bank, STACK_A, "PUSH", 0);
        if (first != want[n] && !select_head(emit, bank, q, first, words, cycles))
            return 0;
        q->id[q->count] = want[n];
        q->ready[q->count++] = queue_clock(words, cycles, saved) + timing[bank].latency;
        repair(emit, STACK_A, bank, "IN", 0);
    }
    return !memcmp(q->id, want, count * sizeof *want);
}

static int
verify(FILE *out, const Schedule *s, int *words, int *cycles)
{
    Emission emit = {.out = out, .schedule = s};
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
                !select_head(&emit, bank, q, src, words, cycles))
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
            if (m.recirculate) {
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
        Bundle dispatch = *b;
        int independent = !b->write_mem;
        for (int j = 0; j < b->count; ++j) {
            int unit = b->move[j].sink_unit;
            if (unit == MEM_READ || unit == PACK || unit == UNPACK ||
                unit == DIV || unit == DIVS || (unit >= STACK_A && unit < CONTROL))
                independent = 0;
        }
        if (independent)
            dispatch.sync = 0;
        emit_bundle(&emit, &dispatch);
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
            if (!restore_order(&emit, bank, q, s->live_out[bank - STASH_A], count, words, cycles))
                return 0;
        } else if (bank < STASH_A) {
            int id = s->result_out[bank];
            if (q->count != !!id || (id && q->id[0] != id))
                return 0;
        } else if (bank != STACK_A && q->count)
            return 0;
    }
    return emit_terminal(&emit, words, cycles);
}

int
schedule_serial_read_wait(void)
{
    /* The old templates consume MEM.CHUNK one or two moves after issuing. */
    return timing[MEM_READ].latency > 2 ? timing[MEM_READ].latency - 2 : 0;
}

static int
serial_schedule(Schedule *s, const Uses *uses)
{
    s->bundle_count = 0;
    for (int i = 1; i <= s->count; ++i)
        if (s->node[i].count) {
            Bundle *b = &s->bundle[s->bundle_count++];
            *b = (Bundle){0};
            if (!pack(b, s, uses, i))
                return 0;
        }
    return 1;
}

static int
temporary_moves(const Schedule *s)
{
    int count = 0;
    for (int i = 0; i < s->bundle_count; ++i)
        for (int n = 0; n < s->bundle[i].count; ++n) {
            struct Transfer move = s->bundle[i].move[n];
            count += move.sink_unit >= STASH_A && move.sink_unit <= STACK_A;
        }
    return count;
}

int
schedule_emit(FILE *out, const SchedRegion *region, int baseline_words, int baseline_cycles)
{
    if (!region->count && region->term.kind == TERM_NONE)
        return 1;
    Schedule *work = emalloc(sizeof *work);
    Schedule *best = emalloc(sizeof *best);
    int best_cycles = INT_MAX, best_words = INT_MAX, best_moves = INT_MAX;
    for (int candidate = 0; candidate < 7; ++candidate) {
        int serial = candidate == 6;
        if (serial && (best_cycles != INT_MAX || baseline_cycles >= 0))
            break;
        memset(work, 0, sizeof *work);
        work->fifo_flow = region->fifo_flow;
        work->term = region->term;
        Uses uses[NODES] = {{0}};
        int reorder = candidate >= 2 && !serial;
        int fanout = candidate == 3 || candidate == 5;
        int unpack = candidate == 4 || candidate == 5;
        if (!expand(work, region, uses, reorder, fanout, unpack))
            continue;
        int ok;
        if (serial)
            ok = serial_schedule(work, uses);
        else if (!build_graph(work, uses, reorder) || (fanout && !collapse_groups(work)))
            continue;
        else if (candidate == 0) {
            ok = latest_first(work, uses);
            qsort(work->bundle, work->bundle_count, sizeof *work->bundle, bundle_order);
        } else
            ok = earliest_first(work, uses);
        int words, cycles;
        if (!ok || !verify(NULL, work, &words, &cycles))
            continue;
        int moves = temporary_moves(work);
        if (cycles < best_cycles || (cycles == best_cycles &&
            (words < best_words || (words == best_words && moves < best_moves)))) {
            best_cycles = cycles;
            best_words = words;
            best_moves = moves;
            Schedule *swap = best;
            best = work;
            work = swap;
        }
    }
    int ok = best_cycles != INT_MAX && (baseline_cycles < 0 || best_cycles < baseline_cycles ||
             (best_cycles == baseline_cycles && best_words < baseline_words));
    if (ok)
        ok = verify(out, best, &best_words, &best_cycles);
    free(work);
    free(best);
    return ok;
}

/* The countdown kernel has a partial ARITH_A request at the loop boundary.
 * A complete request reserves one result generation, even while it computes. */
enum FeedbackPort {
    F_ZERO, F_CONST, F_A_LHS, F_A_RHS, F_A_ADD, F_B_LHS, F_B_RHS, F_B_SUB,
    F_UNPACK_ADDR, F_UNPACK_TYPE, F_UNPACK_CHUNK, F_UNPACK_VALUE,
    F_ARG, F_SEED, F_RESULT, F_CONT, F_COND, F_PC, F_DISCARD, F_PORTS
};

typedef struct {
    enum FeedbackPort source, sink;
} FeedbackMove;

typedef struct {
    FeedbackMove move[5];
    int count, pred;
    const char *immediate;
} FeedbackBundle;

static const char *const feedback_name[] = {
    "ZERO", "CONST", "ARITH_A.LHS", "ARITH_A.RHS", "ARITH_A.ADD",
    "ARITH_B.LHS", "ARITH_B.RHS", "ARITH_B.SUB", "UNPACK.ADDR",
    "UNPACK.TYPE", "UNPACK.CHUNK", "UNPACK.VALUE", "STASH_A.OUT",
    "STASH_B.OUT", "STASH_A.IN", "STACK_B.TOP", "COND", "PC", "DISCARD"
};

static int
feedback_step(unsigned char *state, const FeedbackBundle *bundle, int taken)
{
    unsigned read = 0, write = 0;
    if (bundle->pred) {
        if (!state[F_COND])
            return 0;
        --state[F_COND];
        if (!taken)
            return 1;
    }
    for (int i = 0; i < bundle->count; ++i) {
        enum FeedbackPort src = bundle->move[i].source, dst = bundle->move[i].sink;
        if (src != F_ZERO && src != F_CONST) {
            if (!state[src])
                return 0;
            read |= 1u << src;
        }
        if ((write & (1u << dst)) || (dst != F_PC && dst != F_DISCARD && state[dst] >= 4))
            return 0;
        write |= 1u << dst;
    }
    for (int n = 0; n < F_PORTS; ++n) {
        if (read & (1u << n))
            --state[n];
        if (n != F_PC && n != F_DISCARD && (write & (1u << n)))
            ++state[n];
    }
    const struct {
        enum FeedbackPort lhs, rhs, third, result;
    } units[] = {
        {F_A_LHS, F_A_RHS, F_ZERO, F_A_ADD},
        {F_B_LHS, F_B_RHS, F_ZERO, F_B_SUB},
        {F_UNPACK_ADDR, F_UNPACK_TYPE, F_UNPACK_CHUNK, F_UNPACK_VALUE}
    };
    for (unsigned i = 0; i < sizeof units / sizeof *units; ++i) {
        enum FeedbackPort lhs = units[i].lhs, rhs = units[i].rhs, third = units[i].third;
        if (!state[lhs] || !state[rhs] || (third && !state[third]))
            continue;
        if (state[units[i].result] >= 4)
            return 0;
        --state[lhs];
        --state[rhs];
        if (third)
            --state[third];
        ++state[units[i].result];
    }
    return 1;
}

static void
feedback_print(FILE *out, const FeedbackBundle *bundle)
{
    int width = 0;
    for (int n = 0; n < bundle->count; ++n) {
        int len = strlen(feedback_name[bundle->move[n].source]);
        if (width < len)
            width = len;
    }
    for (int n = 0; n < bundle->count; ++n) {
        FeedbackMove move = bundle->move[n];
        fprintf(out, "%s%-*s -> %s", n ? "  , " : "    ", width,
                feedback_name[move.source], feedback_name[move.sink]);
        if (n + 1 == bundle->count && bundle->immediate)
            fprintf(out, " [%simm=%s]", bundle->pred ? "pred, " : "", bundle->immediate);
        fputc('\n', out);
    }
}

int
schedule_countdown(FILE *out, const char *entry, const char *loop, uint32_t seed, int seed_arg)
{
    char immediate[16];
    snprintf(immediate, sizeof immediate, "0x%"PRIx32, seed);
    const FeedbackBundle bundles[] = {
        {.move = {{seed_arg ? F_SEED : seed ? F_CONST : F_ZERO, F_A_LHS},
                  {F_ARG, F_B_LHS}, {F_ZERO, F_B_RHS}}, .count = 3,
         .immediate = !seed_arg && seed ? immediate : NULL},
        {.move = {{F_B_SUB, F_COND}, {F_B_SUB, F_B_LHS}, {F_CONST, F_B_RHS}, {F_B_SUB, F_A_RHS}},
         .count = 4},
        {.move = {{F_A_ADD, F_A_LHS}, {F_CONST, F_PC}}, .count = 2, .pred = 1, .immediate = loop},
        {.move = {{F_A_ADD, F_UNPACK_CHUNK}, {F_ZERO, F_UNPACK_ADDR}, {F_CONST, F_UNPACK_TYPE},
                  {F_B_SUB, F_DISCARD}}, .count = 4, .immediate = "4"},
        {.move = {{F_UNPACK_VALUE, F_RESULT}, {F_CONT, F_PC}}, .count = 2}
    };
    unsigned char state[F_PORTS] = {[F_ARG] = 1, [F_SEED] = seed_arg, [F_CONT] = 1};
    const unsigned char expected_entry[F_PORTS] = {[F_A_LHS] = 1, [F_B_SUB] = 1, [F_CONT] = 1};
    const unsigned char expected_exit[F_PORTS] = {[F_RESULT] = 1};
    if (!feedback_step(state, &bundles[0], 1) || memcmp(state, expected_entry, sizeof state) ||
        !feedback_step(state, &bundles[1], 1))
        return 0;
    unsigned char back[F_PORTS];
    memcpy(back, state, sizeof back);
    if (!feedback_step(back, &bundles[2], 1) || memcmp(back, expected_entry, sizeof back) ||
        !feedback_step(state, &bundles[2], 0) || !feedback_step(state, &bundles[3], 1) ||
        !feedback_step(state, &bundles[4], 1) || memcmp(state, expected_exit, sizeof state))
        return 0;

    fprintf(out, "%s:\n", entry);
    for (unsigned i = 0; i < sizeof bundles / sizeof *bundles; ++i) {
        if (i == 1)
            fprintf(out, "\n%s:\n", loop);
        feedback_print(out, &bundles[i]);
        if (i > 0 && i < 4)
            fputc('\n', out);
    }
    return 1;
}
