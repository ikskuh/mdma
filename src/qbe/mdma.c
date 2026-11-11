#include "all.h"
#include "schedule.h"
#include <getopt.h>
#include <stdarg.h>

Target T;
char debug['Z'+1];

typedef struct CallEdge CallEdge;
struct CallEdge {
    CallEdge *next;
    char *name;
};

typedef struct Symbol Symbol;
typedef struct InlineBody InlineBody;
enum { INLINE_OPS = 4, INLINE_ARGS = 4 };
struct InlineBody {
    Ins param[INLINE_ARGS], ins[INLINE_OPS];
    unsigned nparam, nins, ntmp;
    int cls;
    Ref result;
    Con con[];
};

struct Symbol {
    Symbol *next;
    char *name, *label;
    int module, origin, function;
    unsigned alignment;
    CallEdge *calls;
    InlineBody *body;
    unsigned nparam;
    unsigned char *param_align;
    int address_taken;
    int indirect, depth, visiting, stack_peak;
};

static Symbol *symbols;
static FILE *out;
static char *input;
static int module, collect, collect_inline, analyze_alignment, alignment_changed, analyze_leaves, optimize = 1;
static Fn *fn;
static Symbol *current_function;
static Blk *block;
static size_t frame_size, phi_base, *objects;
static unsigned serial, max_args;
static unsigned char *tmp_alignment;

#define SP "__mdma_sp"
#define CONT "__mdma_cont"
#define RESULT "__mdma_result"
#define A "STASH_A"
#define B "STASH_B"
#define C "STASH_C"
#define D "STASH_D"

static const char *const abi_stash[] = {A, B, C, D};
enum { FIFO_ARGS = sizeof abi_stash / sizeof *abi_stash };

static void
error(const char *format, ...)
{
    va_list args;
    fprintf(stderr, "qbe-mdma: %s", input ? input : "driver");
    if (fn)
        fprintf(stderr, ": $%s", fn->name);
    if (block)
        fprintf(stderr, ": @%s", block->name);
    fputs(": ", stderr);
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
    fputc('\n', stderr);
    exit(1);
}

static void
line(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vfprintf(out, format, args);
    va_end(args);
    fputc('\n', out);
}

static Symbol *
lookup(const char *name, int scope)
{
    for (Symbol *s = symbols; s; s = s->next)
        if (s->module == scope && strcmp(s->name, name) == 0)
            return s;
    return NULL;
}

static Symbol *
find_symbol(const char *name)
{
    Symbol *s = lookup(name, module);
    return s ? s : lookup(name, 0);
}

static Symbol *
symbol(const char *name)
{
    Symbol *s = find_symbol(name);
    if (!s)
        error("undefined symbol $%s", name);
    return s;
}

static Symbol *
define(const char *name, Lnk *linkage, int function)
{
    int scope = linkage->export ? 0 : module;
    if (linkage->thread || linkage->sec || linkage->common)
        error("unsupported linkage for $%s", name);
    Symbol *public = lookup(name, 0);
    if (lookup(name, scope) || lookup(name, module) || (public && public->origin == module))
        error("duplicate definition of $%s", name);
    Symbol *s = emalloc(sizeof *s);
    size_t length = strlen(name);
    s->name = emalloc(length + 1);
    strcpy(s->name, name);
    s->label = emalloc(32 + 2 * length);
    char *p = s->label + sprintf(s->label, "__mdma_g%d_", scope);
    for (const unsigned char *c = (const unsigned char *)name; *c; ++c)
        p += sprintf(p, "%02x", *c);
    s->module = scope;
    s->origin = module;
    s->function = function;
    s->stack_peak = -1;
    s->alignment = linkage->align < 8 ? 8 : linkage->align;
    s->next = symbols;
    symbols = s;
    return s;
}

static void
move(const char *source, const char *sink)
{
    line("%s -> %s", source, sink);
}

static void
literal(const char *value, const char *sink)
{
    line("CONST -> %s [imm=%s]", sink, value);
}

static void
number(uint64_t value, const char *sink)
{
    line("CONST -> %s [imm=0x%"PRIx64"]", sink, value);
}

static void
load_global(const char *label, const char *sink)
{
    literal(label, "MEM.READ");
    move("MEM.CHUNK", sink);
}

static void
store_global(const char *label, const char *source)
{
    line("CONST -> MEM.WRITE, %s -> MEM.CHUNK, ZERO -> MEM.MASK [sync, imm=%s]", source, label);
}

static void
address(size_t offset, const char *sink)
{
    load_global(SP, "ARITH_B.LHS");
    line("CONST -> ARITH_B.RHS [imm=%"PRId64"]", (int64_t)offset - (int64_t)frame_size);
    move("ARITH_B.ADD", sink);
}

static void
load_frame(size_t offset, const char *sink)
{
    address(offset, "MEM.READ");
    move("MEM.CHUNK", sink);
}

static void
store_frame(size_t offset, const char *source)
{
    /* Address calculation itself reads memory. Preserve the value first. */
    if (strcmp(source, D))
        move(source, D);
    address(offset, "MEM.WRITE");
    line(D " -> MEM.CHUNK, ZERO -> MEM.MASK [sync]");
}

static size_t
slot(Ref ref)
{
    if (rtype(ref) != RTmp || ref.val < Tmp0)
        error("expected a temporary");
    return 8 * (1 + (size_t)(ref.val - Tmp0));
}

static void
value(Ref ref, const char *sink)
{
    if (rtype(ref) == RTmp) {
        load_frame(slot(ref), sink);
    } else if (rtype(ref) == RCon) {
        Con *con = &fn->con[ref.val];
        if (con->flt)
            error("floating-point operand");
        if (con->type == CAddr) {
            if (con->sym.type & SThr)
                error("thread-local reference");
            const char *label = symbol(str(con->sym.id))->label;
            if (con->bits.i) {
                literal(label, "ARITH_B.LHS");
                number(con->bits.i, "ARITH_B.RHS");
                move("ARITH_B.ADD", sink);
            } else {
                literal(label, sink);
            }
        } else {
            number(req(ref, UNDEF) ? 0 : (uint64_t)con->bits.i, sink);
        }
    } else {
        error("unsupported operand");
    }
}

static void
extend(const char *source, const char *sink, unsigned bits, int sign)
{
    if (sign) {
        line("%s -> SHIFT_B.VAL, CONST -> SHIFT_B.CNT [sync, imm=%u]", source, 64 - bits);
        line("SHIFT_B.LSL -> SHIFT_B.VAL, CONST -> SHIFT_B.CNT [sync, imm=%u]", 64 - bits);
        move("SHIFT_B.ASR", sink);
    } else {
        line("%s -> LOGIC_B.LHS, CONST -> LOGIC_B.RHS [sync, imm=0x%"PRIx64"]",
             source, (UINT64_C(1) << bits) - 1);
        move("LOGIC_B.AND", sink);
    }
}

static void
save(Ref to, int cls, const char *source)
{
    if (cls == Kw) {
        extend(source, D, 32, 0);
        source = D;
    }
    store_frame(slot(to), source);
}

static void
typed_load(const char *addr, unsigned type, const char *sink)
{
    line("%s -> MEM.READ, %s -> UNPACK.ADDR, CONST -> UNPACK.TYPE [sync, imm=%u]", addr, addr, type);
    move("MEM.CHUNK", "UNPACK.CHUNK");
    move("UNPACK.VALUE", sink);
}

static void
typed_store(const char *addr, const char *source, unsigned type)
{
    line("%s -> PACK.ADDR, %s -> PACK.VALUE, CONST -> PACK.TYPE [sync, imm=%u]", addr, source, type);
    line("PACK.ADDR -> MEM.WRITE, PACK.CHUNK -> MEM.CHUNK, PACK.MASK -> MEM.MASK [sync]");
}

/* A and B hold the address and store value. On load, leave the result in D. */
static void
memory(unsigned bytes, int sign, int store)
{
    unsigned type = 0;
    for (unsigned n = bytes; n > 1; n /= 2)
        type += 2;
    if (bytes == 1) {
        if (store)
            typed_store(A, B, 0);
        else
            typed_load(A, sign, D);
        return;
    }
    unsigned id = serial++;
    line(A " -> " A ", " A " -> LOGIC_A.LHS, CONST -> LOGIC_A.RHS [sync, imm=%u]", bytes - 1);
    move("LOGIC_A.AND", "COND");
    line("CONST -> PC_REL [pred, rel=__mdma_unaligned_%u]", id);
    if (store)
        typed_store(A, B, type);
    else
        typed_load(A, type + sign, D);
    line("CONST -> PC_REL [rel=__mdma_aligned_%u]", id);
    line("__mdma_unaligned_%u:", id);
    if (!store)
        move("ZERO", C);
    for (unsigned i = 0; i < bytes; ++i) {
        line(A " -> " A ", " A " -> ARITH_A.LHS, CONST -> ARITH_A.RHS [sync, imm=%u]", i);
        if (store) {
            line(B " -> " B ", " B " -> SHIFT_A.VAL, CONST -> SHIFT_A.CNT [sync, imm=%u]", 8 * i);
            typed_store("ARITH_A.ADD", "SHIFT_A.LSR", 0);
        } else {
            typed_load("ARITH_A.ADD", 0, "SHIFT_A.VAL");
            number(8 * i, "SHIFT_A.CNT");
            line("SHIFT_A.LSL -> LOGIC_A.LHS, " C " -> LOGIC_A.RHS [sync]");
            move("LOGIC_A.OR", C);
        }
    }
    move(A, "DISCARD");
    if (store)
        move(B, "DISCARD");
    else if (sign && bytes < 8)
        extend(C, D, bytes * 8, 1);
    else
        move(C, D);
    line("__mdma_aligned_%u:", id);
}

static void
binary(Ins *i, const char *unit, const char *result, int signed_operands)
{
    value(i->arg[0], A);
    value(i->arg[1], B);
    if (i->cls == Kw && signed_operands) {
        extend(A, A, 32, 1);
        extend(B, B, 32, 1);
    } else if (i->cls == Kw && (i->op == Oudiv || i->op == Ourem)) {
        extend(A, A, 32, 0);
        extend(B, B, 32, 0);
    }
    line(A " -> %s.LHS, " B " -> %s.RHS [sync]", unit, unit);
    char source[32];
    snprintf(source, sizeof source, "%s.%s", unit, result);
    save(i->to, i->cls, source);
}

static const char *const cmp_results[] = {"EQ", "NE", "LTES", "LTS", "LTES", "LTS",
                                          "LTE", "LT", "LTE", "LT"};

static void
compare(Ins *i)
{
    unsigned cmp = i->op >= Ocmpl ? i->op - Ocmpl : i->op - Ocmpw;
    int sign = cmp >= Cisge && cmp <= Cislt;
    int reverse = cmp == Cisge || cmp == Cisgt || cmp == Ciuge || cmp == Ciugt;
    value(i->arg[0], A);
    value(i->arg[1], B);
    if (i->op < Ocmpl) {
        extend(A, A, 32, sign);
        extend(B, B, 32, sign);
    }
    line("%s -> CMP.LHS, %s -> CMP.RHS [sync]", reverse ? B : A, reverse ? A : B);
    char source[16];
    snprintf(source, sizeof source, "CMP.%s", cmp_results[cmp]);
    store_frame(slot(i->to), source);
}

static void
shift(Ins *i)
{
    value(i->arg[0], A);
    value(i->arg[1], B);
    if (i->cls == Kw)
        extend(A, A, 32, i->op == Osar);
    extend(B, B, i->cls == Kw ? 5 : 6, 0);
    line(A " -> SHIFT_A.VAL, " B " -> SHIFT_A.CNT [sync]");
    save(i->to, i->cls, i->op == Oshl ? "SHIFT_A.LSL" : i->op == Oshr ? "SHIFT_A.LSR" : "SHIFT_A.ASR");
}

static void
arg_label(char label[32], unsigned arg)
{
    snprintf(label, 32, "__mdma_arg_%u", arg);
}

static int
continuation_depth(Symbol *s)
{
    if (s->depth || s->visiting)
        return s->depth;
    s->visiting = 1;
    int depth = s->indirect ? 0 : 1;
    for (CallEdge *edge = s->calls; depth && edge; edge = edge->next) {
        Symbol *callee = lookup(edge->name, s->origin);
        if (!callee)
            callee = lookup(edge->name, 0);
        int child = callee && callee->function ? continuation_depth(callee) : 0;
        if (child <= 0 || child == 8)
            depth = 0;
        else if (depth <= child)
            depth = child + 1;
    }
    s->visiting = 0;
    return s->depth = depth ? depth : -1;
}

static Symbol *
call_target(Ref ref)
{
    Con *con = &fn->con[ref.val];
    if (con->type != CAddr || con->bits.i || (con->sym.type & SThr))
        error("invalid direct call target");
    Symbol *callee = symbol(str(con->sym.id));
    if (!callee->function)
        error("call target $%s is data", callee->name);
    return callee;
}

static void
call_argument(Ins *arg)
{
    if ((arg->op != Oarg && !isargbh(arg->op)) || arg->cls > Kl)
        error("unsupported call argument");
    value(arg->arg[0], D);
    if (isargbh(arg->op)) {
        unsigned index = arg->op - Oargsb;
        extend(D, D, index < 2 ? 8 : 16, !(index & 1));
        if (optimize && !(index & 1))
            extend(D, D, 32, 0);
    } else if (arg->cls == Kw) {
        extend(D, D, 32, 0);
    }
}

static void
fifo_call(Ins *i, Ins *args, unsigned argc)
{
    int park = current_function->depth < 0;
    if (park)
        store_frame(0, "STACK_B.TOP");
    for (unsigned n = FIFO_ARGS; n < argc; ++n) {
        char label[32];
        call_argument(&args[n]);
        arg_label(label, n);
        store_global(label, D);
    }
    for (unsigned n = 0; n < argc && n < FIFO_ARGS; ++n) {
        call_argument(&args[n]);
        if (n != FIFO_ARGS - 1)
            move(D, abi_stash[n]);
    }
    if (rtype(i->arg[0]) == RCon)
        line("PC_NEXT -> STACK_B.PUSH, CONST -> PC_REL [sync, rel=%s]", call_target(i->arg[0])->label);
    else {
        value(i->arg[0], "STACK_A.PUSH");
        line("PC_NEXT -> STACK_B.PUSH, STACK_A.TOP -> PC [sync]");
    }
    if (req(i->to, R))
        move(A, "DISCARD");
    else
        move(A, D);
    if (park)
        load_frame(0, "STACK_B.PUSH");
    if (!req(i->to, R))
        save(i->to, i->cls, D);
}

static void
call(Ins *i, Ins *args, unsigned argc)
{
    if (rtype(i->arg[1]) == RType || i->cls > Kl)
        error("unsupported call result type");
    if (optimize) {
        fifo_call(i, args, argc);
        return;
    }
    for (unsigned n = 0; n < argc; ++n) {
        call_argument(&args[n]);
        char label[32];
        arg_label(label, n);
        store_global(label, D);
    }
    unsigned id = serial++;
    line("CONST -> MEM.WRITE, ZERO -> MEM.MASK [imm=" CONT "]");
    line("CONST -> MEM.CHUNK [imm=__mdma_return_%u]", id);
    if (rtype(i->arg[0]) == RCon)
        line("CONST -> PC_REL [rel=%s]", call_target(i->arg[0])->label);
    else
        value(i->arg[0], "PC");
    line("__mdma_return_%u:", id);
    if (!req(i->to, R)) {
        load_global(RESULT, D);
        save(i->to, i->cls, D);
    }
}

static void
instruction(Ins *i)
{
    if (i->cls > Kl)
        error("unsupported type for %s", optab[i->op].name);
    if (INRANGE(i->op, Ocmpw, Ocmpl1)) {
        compare(i);
        return;
    }
    switch (i->op) {
    case Onop: case Odbgloc:
        break;
    case Oadd: binary(i, "ARITH_A", "ADD", 0); break;
    case Osub: binary(i, "ARITH_A", "SUB", 0); break;
    case Omul: binary(i, "MUL", "LO", 0); break;
    case Odiv: binary(i, "DIVS", "QUO", 1); break;
    case Orem: binary(i, "DIVS", "REM", 1); break;
    case Oudiv: binary(i, "DIV", "QUO", 0); break;
    case Ourem: binary(i, "DIV", "REM", 0); break;
    case Oand: binary(i, "LOGIC_A", "AND", 0); break;
    case Oor: binary(i, "LOGIC_A", "OR", 0); break;
    case Oxor: binary(i, "LOGIC_A", "XOR", 0); break;
    case Oshl: case Oshr: case Osar: shift(i); break;
    case Ocopy:
        value(i->arg[0], D);
        save(i->to, i->cls, D);
        break;
    case Oneg:
        value(i->arg[0], "UOP_A.IN");
        save(i->to, i->cls, "UOP_A.NEG");
        break;
    case Oextsb: case Oextub: case Oextsh: case Oextuh: case Oextsw: case Oextuw: {
        unsigned k = i->op - Oextsb;
        value(i->arg[0], D);
        extend(D, D, k < 2 ? 8 : k < 4 ? 16 : 32, !(k & 1));
        save(i->to, i->cls, D);
        break;
    }
    case Oalloc4: case Oalloc8: case Oalloc16:
        address(objects[slot(i->to) / 8], D);
        store_frame(slot(i->to), D);
        break;
    case Oloadsb: case Oloadub: case Oloadsh: case Oloaduh: case Oloadsw: case Oloaduw: case Oload: {
        unsigned k = i->op - Oloadsb;
        value(i->arg[0], A);
        memory(loadsz(i), i->op != Oload && !(k & 1), 0);
        save(i->to, i->cls, D);
        break;
    }
    case Ostoreb: case Ostoreh: case Ostorew: case Ostorel:
        value(i->arg[1], A);
        value(i->arg[0], B);
        memory(1u << (i->op - Ostoreb), 0, 1);
        break;
    default:
        error("unsupported operation %s", optab[i->op].name);
    }
}

/* The block-local optimizer uses SSA IDs until it lowers the region to moves. */
static SchedRegion scheduled;
static SchedValue *scheduled_value, scheduled_sp;
static unsigned char *scheduled_known, *uncanonical_word;
static int schedule_overflow, fifo_only;
static size_t *fifo_spill;

static SchedValue
sched_number(uint64_t value)
{
    if (!value)
        return (SchedValue){0};
    char *imm = alloc(32);
    if (value >= UINT64_MAX - 2047)
        snprintf(imm, 32, "%"PRId64, (int64_t)value);
    else
        snprintf(imm, 32, "0x%"PRIx64, value);
    return (SchedValue){.imm = imm};
}

static SchedValue
sched_node(enum SchedUnit unit, const char *result, int count, const SchedMove *moves)
{
    if (scheduled.count == SCHED_NODES) {
        schedule_overflow = 1;
        return (SchedValue){0};
    }
    SchedMove operands[5];
    for (int n = 0; n < count; ++n) {
        operands[n] = moves[n];
        int id = moves[n].value.node;
        if (!fifo_only || !id)
            continue;
        enum SchedUnit bank = scheduled.node[id - 1].unit;
        for (int m = 0; bank >= STASH_A && bank <= STASH_D && m < n; ++m) {
            int other = operands[m].value.node;
            if (other && other != id && scheduled.node[other - 1].unit == bank) {
                operands[n].value = sched_node(HOLD, "OUT", 1, (SchedMove[]){{NULL, moves[n].value}});
                break;
            }
        }
    }
    if (schedule_overflow || scheduled.count == SCHED_NODES) {
        schedule_overflow = 1;
        return (SchedValue){0};
    }
    SchedNode *node = &scheduled.node[scheduled.count++];
    *node = (SchedNode){.unit = unit, .result = result, .count = count};
    if (count)
        memcpy(node->move, operands, count * sizeof *moves);
    /* An instruction has one immediate. Stage conflicting constants as values
     * and let the allocator place them in a STASH or STACK. */
    const char *first = NULL;
    for (int n = 0; n < count; ++n) {
        SchedValue operand = node->move[n].value;
        if (!operand.imm)
            continue;
        if (!first) {
            first = operand.imm;
            continue;
        }
        if (!strcmp(first, operand.imm))
            continue;
        if (scheduled.count == SCHED_NODES) {
            schedule_overflow = 1;
            return (SchedValue){0};
        }
        node[1] = *node;
        *node = (SchedNode){.unit = HOLD, .result = "OUT", .count = 1,
                            .move = {{NULL, operand}}};
        node = &scheduled.node[scheduled.count++];
        node->move[n].value = (SchedValue){.node = scheduled.count - 1};
    }
    return (SchedValue){.node = scheduled.count};
}

static SchedValue
sched_pair(enum SchedUnit unit, const char *result, SchedValue lhs, SchedValue rhs)
{
    int shift_unit = unit == SHIFT_A || unit == SHIFT_B;
    return sched_node(unit, result, 2, (SchedMove[]){
        {shift_unit ? "VAL" : "LHS", lhs}, {shift_unit ? "CNT" : "RHS", rhs}
    });
}

static SchedValue
sched_read(SchedValue addr)
{
    return sched_node(MEM_READ, "CHUNK", 1, (SchedMove[]){{"READ", addr}});
}

static void
sched_write(SchedValue addr, SchedValue chunk, SchedValue mask)
{
    sched_node(MEM_WRITE, NULL, 3, (SchedMove[]){{"WRITE", addr}, {"CHUNK", chunk}, {"MASK", mask}});
}

static SchedValue
sched_address(size_t offset)
{
    if (!scheduled_sp.node)
        scheduled_sp = sched_read((SchedValue){.imm = SP});
    return sched_pair(ARITH_A, "ADD", scheduled_sp, sched_number(offset - frame_size));
}

static int flow_rematerialize(int temp);

static SchedValue
sched_value(Ref ref)
{
    if (rtype(ref) == RTmp) {
        SchedValue *saved = &scheduled_value[ref.val];
        if (!scheduled_known[ref.val]) {
            if (fifo_only && flow_rematerialize(ref.val)) {
                Ref arg = fn->tmp[ref.val].def->arg[0];
                Con *c = &fn->con[arg.val];
                if (fn->tmp[ref.val].cls != Kw)
                    *saved = sched_value(arg);
                else if (c->type == CAddr)
                    *saved = sched_pair(LOGIC_A, "AND", sched_value(arg), sched_number(UINT32_MAX));
                else
                    *saved = sched_number((uint32_t)c->bits.i);
                scheduled_known[ref.val] = 1;
                return *saved;
            }
            if (fifo_only && !fifo_spill[ref.val]) {
                schedule_overflow = 1;
                return (SchedValue){0};
            }
            size_t offset = fifo_only ? fifo_spill[ref.val] - 1 : slot(ref);
            *saved = sched_read(sched_address(offset));
            scheduled_known[ref.val] = 1;
        }
        return *saved;
    }
    if (rtype(ref) != RCon)
        error("unsupported operand");
    Con *con = &fn->con[ref.val];
    if (con->flt)
        error("floating-point operand");
    if (con->type == CAddr) {
        if (con->sym.type & SThr)
            error("thread-local reference");
        SchedValue label = {.imm = symbol(str(con->sym.id))->label};
        return con->bits.i ? sched_pair(ARITH_A, "ADD", label, sched_number(con->bits.i)) : label;
    }
    return sched_number(req(ref, UNDEF) ? 0 : (uint64_t)con->bits.i);
}

static int
sched_constant(SchedValue value, uint64_t *number, unsigned budget)
{
    if (!budget)
        return 0;
    if (!value.node) {
        if (!value.imm) {
            *number = 0;
            return 1;
        }
        char *end;
        *number = strtoull(value.imm, &end, 0);
        return !*end;
    }
    const SchedNode *node = &scheduled.node[value.node - 1];
    if (node->unit == HOLD && node->count == 1)
        return sched_constant(node->move[0].value, number, budget - 1);
    return 0;
}

static int
sched_narrow(SchedValue value, unsigned width, unsigned budget)
{
    uint64_t number;
    if (sched_constant(value, &number, budget))
        return !(number >> width);
    if (!budget || !value.node)
        return 0;
    const SchedNode *node = &scheduled.node[value.node - 1];
    if (node->unit == CMP)
        return 1;
    if (!node->result || (value.port && strcmp(value.port, node->result)))
        return 0;
    if ((node->unit == HOLD || (node->unit >= STASH_A && node->unit <= STACK_A)) && node->count == 1)
        return sched_narrow(node->move[0].value, width, budget - 1);
    if ((node->unit == LOGIC_A || node->unit == LOGIC_B) && node->count == 2) {
        if (!strcmp(node->result, "AND"))
            return sched_narrow(node->move[0].value, width, budget - 1) ||
                   sched_narrow(node->move[1].value, width, budget - 1);
        if (!strcmp(node->result, "OR") || !strcmp(node->result, "XOR"))
            return sched_narrow(node->move[0].value, width, budget - 1) &&
                   sched_narrow(node->move[1].value, width, budget - 1);
    }
    if (node->unit == UNPACK && !strcmp(node->result, "VALUE"))
        for (int i = 0; i < node->count; ++i)
            if (!strcmp(node->move[i].sink, "TYPE") &&
                sched_constant(node->move[i].value, &number, budget - 1))
                return number <= 4 && !(number & 1) && (8u << (number / 2)) <= width;
    return 0;
}

static SchedValue
sched_extend(SchedValue value, unsigned width, int sign)
{
    /* Signed extension also preserves values whose sign bit is known zero. */
    if (sched_narrow(value, width - sign, 16))
        return value;
    uint64_t mask = (UINT64_C(1) << width) - 1;
    if (!value.node) {
        if (!value.imm)
            return value;
        char *end;
        uint64_t number = strtoull(value.imm, &end, 0);
        if (!*end) {
            number &= mask;
            uint64_t sign_bit = UINT64_C(1) << (width - 1);
            if (sign && (number & sign_bit))
                number |= ~mask;
            return sched_number(number);
        }
    }
    if (sign) {
        unsigned type = width == 8 ? 1 : width == 16 ? 3 : 5;
        return sched_node(UNPACK, "VALUE", 3, (SchedMove[]){
            {"ADDR", {0}}, {"TYPE", sched_number(type)}, {"CHUNK", value}
        });
    }
    return sched_pair(LOGIC_A, "AND", value, sched_number(mask));
}

static int plain_constant(Ref ref);

static unsigned
value_alignment(uint64_t value)
{
    return value & 1 ? 1 : value & 2 ? 2 : value & 4 ? 4 : 8;
}

static unsigned
ref_alignment(Ref ref)
{
    if (rtype(ref) == RTmp && ref.val >= Tmp0)
        return tmp_alignment[ref.val];
    if (rtype(ref) == RCon) {
        Con *c = &fn->con[ref.val];
        if (c->type == CBits && !c->flt)
            return value_alignment(c->bits.i);
        if (c->type == CAddr) {
            Symbol *s = find_symbol(str(c->sym.id));
            if (s) {
                unsigned offset = value_alignment(c->bits.i);
                return offset < s->alignment ? offset : s->alignment;
            }
        }
    }
    return 1;
}

static unsigned
operation_alignment(const Ins *def)
{
    if (isalloc(def->op))
        return def->op == Oalloc4 ? 4 : 8;
    unsigned lhs = ref_alignment(def->arg[0]);
    unsigned rhs = ref_alignment(def->arg[1]);
    switch (def->op) {
    case Ocopy: case Oneg:
        return lhs;
    case Oadd: case Osub: case Oor: case Oxor:
        return lhs < rhs ? lhs : rhs;
    case Oand:
        return lhs > rhs ? lhs : rhs;
    case Omul:
        return lhs * rhs < 8 ? lhs * rhs : 8;
    case Oshl:
        if (plain_constant(def->arg[1])) {
            unsigned mask = def->cls == Kw ? 31 : 63;
            unsigned shift = fn->con[def->arg[1].val].bits.i & mask;
            if (shift >= 3)
                return 8;
            lhs <<= shift;
        }
        return lhs < 8 ? lhs : 8;
    default:
        return isext(def->op) ? lhs : 1;
    }
}

static unsigned
memory_width(Ins *i)
{
    return isstore(i->op) ? storesz(i) : loadsz(i);
}

static int
sched_eligible(Ins *i)
{
    if (i->cls > Kl)
        return 0;
    if (INRANGE(i->op, Ocmpw, Ocmpl1))
        return 1;
    if (isload(i->op) || isstore(i->op))
        return 1;
    return i->op == Onop || i->op == Odbgloc || i->op == Ocopy || i->op == Oneg ||
           i->op == Oadd || i->op == Osub || i->op == Omul || i->op == Oand ||
           i->op == Oor || i->op == Oxor || i->op == Oshl || i->op == Oshr ||
           i->op == Osar || isext(i->op);
}

static SchedValue
sched_memory(Ins *i, SchedValue lhs, SchedValue rhs)
{
    unsigned bytes = memory_width(i);
    if (isload(i->op) && ref_alignment(i->arg[0]) < bytes) {
        /* Read the words containing the first and last requested bytes. */
        SchedValue lo = sched_read(lhs);
        SchedValue end = sched_pair(ARITH_A, "ADD", lhs, sched_number(bytes - 1));
        SchedValue hi = sched_read(end);
        /* SHIFT uses the low six count bits. At offset zero both reads
         * return the same word, so OR still gives the right result. */
        SchedValue count = sched_pair(SHIFT_A, "LSL", lhs, sched_number(3));
        SchedValue reverse = sched_node(UOP_A, "NEG", 1, (SchedMove[]){{"IN", count}});
        lo = sched_pair(SHIFT_A, "LSR", lo, count);
        hi = sched_pair(SHIFT_A, "LSL", hi, reverse);
        SchedValue chunk = sched_pair(LOGIC_A, "OR", lo, hi);
        int sign = i->op != Oload && !((i->op - Oloadsb) & 1);
        return bytes == 8 ? chunk : sched_extend(chunk, bytes * 8, sign);
    }
    if (isstore(i->op) && ref_alignment(i->arg[1]) < bytes) {
        SchedValue end = sched_pair(ARITH_A, "ADD", rhs, sched_number(bytes - 1));
        SchedValue lane = sched_pair(LOGIC_A, "AND", rhs, sched_number(7));
        SchedValue count = sched_pair(SHIFT_A, "LSL", rhs, sched_number(3));
        SchedValue reverse = sched_node(UOP_A, "NEG", 1, (SchedMove[]){{"IN", count}});
        /* Each set bit in the memory mask disables one byte lane. The
         * upper mask disables every lane when the store fits in one word. */
        SchedValue enable = sched_pair(SHIFT_A, "LSL", sched_number((1u << bytes) - 1), lane);
        SchedValue mask = sched_node(UOP_A, "NOT", 1, (SchedMove[]){{"IN", enable}});
        SchedValue upper = sched_pair(SHIFT_A, "LSR", mask, sched_number(8));
        SchedValue lo = sched_pair(SHIFT_A, "LSL", lhs, count);
        SchedValue hi = sched_pair(SHIFT_A, "LSR", lhs, reverse);
        sched_write(rhs, lo, mask);
        sched_write(end, hi, upper);
        return (SchedValue){0};
    }
    if (bytes == 8) {
        if (isload(i->op))
            return sched_read(lhs);
        sched_write(rhs, lhs, (SchedValue){0});
        return (SchedValue){0};
    }
    unsigned type = bytes == 1 ? 0 : bytes == 2 ? 2 : 4;
    if (isload(i->op)) {
        SchedValue chunk = sched_read(lhs);
        int sign = i->op != Oload && !((i->op - Oloadsb) & 1);
        return sched_node(UNPACK, "VALUE", 3, (SchedMove[]){
            {"ADDR", lhs}, {"TYPE", sched_number(type + sign)}, {"CHUNK", chunk}
        });
    }
    SchedValue addr = sched_node(PACK, "ADDR", 3, (SchedMove[]){
        {"ADDR", rhs}, {"TYPE", sched_number(type)}, {"VALUE", lhs}
    });
    sched_write(addr, (SchedValue){.node = addr.node, .port = "CHUNK"},
                      (SchedValue){.node = addr.node, .port = "MASK"});
    return (SchedValue){0};
}

typedef struct {
    enum SchedUnit unit;
    const char *port;
} ResultHome;

static ResultHome *result_home;

typedef struct {
    const Ins *shift;
    unsigned offset, type;
} LaneExtract;

static LaneExtract
lane_extract(const Ins *i, const Ins *first)
{
    Ref value = i->arg[0];
    unsigned width, sign = 0;
    if (i->op == Oand) {
        Ref mask = i->arg[1];
        if (!plain_constant(mask)) {
            mask = value;
            value = i->arg[1];
        }
        if (!plain_constant(mask))
            return (LaneExtract){0};
        uint64_t bits = fn->con[mask.val].bits.i;
        if (i->cls == Kw)
            bits = (uint32_t)bits;
        width = bits == UINT8_MAX ? 8 : bits == UINT16_MAX ? 16 : bits == UINT32_MAX ? 32 : 0;
        if (!width)
            return (LaneExtract){0};
    } else if (isext(i->op)) {
        unsigned kind = i->op - Oextsb;
        width = 8u << (kind / 2);
        sign = !(kind & 1);
    } else {
        return (LaneExtract){0};
    }

    /* A result carried across blocks must still come from its assigned FU. */
    if (scheduled.fifo_flow && result_home[i->to.val].port)
        return (LaneExtract){0};
    if (rtype(value) != RTmp)
        return (LaneExtract){0};
    const Tmp *t = &fn->tmp[value.val];
    const Ins *shift = t->def;
    /* Drop only a shift whose sole consumer is in this scheduling region. */
    if (t->bid != block->id || t->nuse != 1 || !shift || shift < first || shift >= i ||
        (shift->op != Oshr && shift->op != Osar) || !plain_constant(shift->arg[1]))
        return (LaneExtract){0};
    unsigned bits = shift->cls == Kw ? 32 : 64;
    unsigned count = fn->con[shift->arg[1].val].bits.i & (bits - 1);
    if (!count || count % width || count + width > bits)
        return (LaneExtract){0};
    return (LaneExtract){shift, count / 8, (width == 8 ? 0 : width == 16 ? 2 : 4) + sign};
}

static int
folded_shift(const Ins *i, const Ins *first, const Ins *end)
{
    if (i->op != Oshr && i->op != Osar)
        return 0;
    const Tmp *t = &fn->tmp[i->to.val];
    if (t->nuse != 1 || t->use[0].type != UIns || t->use[0].bid != block->id)
        return 0;
    const Ins *consumer = t->use[0].u.ins;
    return consumer < end && lane_extract(consumer, first).shift == i;
}

static SchedValue
sched_instruction(Ins *i, const Ins *first)
{
    LaneExtract extract = lane_extract(i, first);
    if (extract.shift)
        return sched_node(UNPACK, "VALUE", 3, (SchedMove[]){
            {"ADDR", sched_number(extract.offset)}, {"TYPE", sched_number(extract.type)},
            {"CHUNK", sched_value(extract.shift->arg[0])}
        });
    SchedValue lhs = sched_value(i->arg[0]);
    SchedValue rhs = req(i->arg[1], R) ? (SchedValue){0} : sched_value(i->arg[1]);
    if (isload(i->op) || isstore(i->op))
        return sched_memory(i, lhs, rhs);
    if (INRANGE(i->op, Ocmpw, Ocmpl1)) {
        unsigned cmp = i->op >= Ocmpl ? i->op - Ocmpl : i->op - Ocmpw;
        int sign = cmp >= Cisge && cmp <= Cislt;
        int reverse = cmp == Cisge || cmp == Cisgt || cmp == Ciuge || cmp == Ciugt;
        if (i->op < Ocmpl && sign) {
            lhs = sched_extend(lhs, 32, 1);
            rhs = sched_extend(rhs, 32, 1);
        } else if (i->op < Ocmpl) {
            /* Word constants may carry high bits even though SSA words do not. */
            if (rtype(i->arg[0]) != RTmp || fn->tmp[i->arg[0].val].cls != Kw)
                lhs = sched_extend(lhs, 32, 0);
            if (rtype(i->arg[1]) != RTmp || fn->tmp[i->arg[1].val].cls != Kw)
                rhs = sched_extend(rhs, 32, 0);
        }
        return sched_pair(CMP, cmp_results[cmp], reverse ? rhs : lhs, reverse ? lhs : rhs);
    }
    switch (i->op) {
    case Oadd: return sched_pair(ARITH_A, "ADD", lhs, rhs);
    case Osub: return sched_pair(ARITH_A, "SUB", lhs, rhs);
    case Omul: return sched_pair(MUL, "LO", lhs, rhs);
    case Oand: return sched_pair(LOGIC_A, "AND", lhs, rhs);
    case Oor: return sched_pair(LOGIC_A, "OR", lhs, rhs);
    case Oxor: return sched_pair(LOGIC_A, "XOR", lhs, rhs);
    case Oneg: return sched_node(UOP_A, "NEG", 1, (SchedMove[]){{"IN", lhs}});
    case Oshl: case Oshr: case Osar:
        if (i->cls == Kw) {
            if (i->op == Osar || (i->op == Oshr &&
                (rtype(i->arg[0]) != RTmp || fn->tmp[i->arg[0].val].cls != Kw)))
                lhs = sched_extend(lhs, 32, i->op == Osar);
            rhs = sched_extend(rhs, 5, 0);
        }
        return sched_pair(SHIFT_A, i->op == Oshl ? "LSL" : i->op == Oshr ? "LSR" : "ASR", lhs, rhs);
    case Ocopy: return lhs;
    default: {
        unsigned k = i->op - Oextsb;
        return sched_extend(lhs, k < 2 ? 8 : k < 4 ? 16 : 32, !(k & 1));
    }
    }
}

static int
local_result(Ref ref, const Ins *first, const Ins *end)
{
    Tmp *tmp = &fn->tmp[ref.val];
    if (!tmp->nuse)
        return 0;
    for (unsigned n = 0; n < tmp->nuse; ++n) {
        Use *use = &tmp->use[n];
        if (use->bid != block->id || use->type != UIns ||
            use->u.ins < first || use->u.ins >= end)
            return 0;
    }
    return 1;
}

static int
sched_region(Ins *first, Ins *end, int words, int cycles)
{
    scheduled.fifo_flow = 0;
    scheduled.count = schedule_overflow = 0;
    scheduled.term = (SchedTerm){0};
    scheduled_sp = (SchedValue){0};
    memset(scheduled.live_out, 0, sizeof scheduled.live_out);
    memset(scheduled.result_out, 0, sizeof scheduled.result_out);
    memset(scheduled.saved, 0, sizeof scheduled.saved);
    scheduled_sp = (SchedValue){0};
    memset(scheduled_known, 0, fn->ntmp * sizeof *scheduled_known);
    for (Ins *i = first; i < end && !schedule_overflow; ++i) {
        if (i->op == Onop || i->op == Odbgloc)
            continue;
        if (folded_shift(i, first, end))
            continue;
        SchedValue result = sched_instruction(i, first);
        if (req(i->to, R))
            continue;
        if (i->cls == Kw && !INRANGE(i->op, Ocmpw, Ocmpl1))
            result = sched_extend(result, 32, 0);
        if (!local_result(i->to, first, end))
            sched_write(sched_address(slot(i->to)), result, (SchedValue){0});
        scheduled_value[i->to.val] = result;
        scheduled_known[i->to.val] = 1;
    }
    return !schedule_overflow && schedule_emit(out, &scheduled, words, cycles);
}

static void
emit_region(Ins *first, Ins *end)
{
    char *baseline = NULL;
    size_t size = 0;
    FILE *saved = out;
    out = open_memstream(&baseline, &size);
    if (!out)
        error("cannot buffer unscheduled region");
    for (Ins *i = first; i < end; ++i)
        instruction(i);
    if (fclose(out))
        error("cannot buffer unscheduled region");
    out = saved;
    int words = 0, cycles = 0;
    for (char *p = baseline; *p;) {
        char *next = strchr(p, '\n');
        *next = 0;
        const char *imm = strstr(p, "imm=");
        const char *read = strstr(p, "MEM.CHUNK ->");
        ++words;
        ++cycles;
        if (read)
            cycles += schedule_serial_read_wait();
        if (strstr(p, "rel="))
            ++words;
        if (imm) {
            char *tail;
            int64_t value = strtoll(imm + 4, &tail, 0);
            if (*tail != ']' || value < -2048 || value > 4095)
                ++words;
        }
        *next = '\n';
        p = next + 1;
    }
    if (!sched_region(first, end, words, cycles)) {
        if (end - first > 1) {
            Ins *middle = first + (end - first) / 2;
            emit_region(first, middle);
            emit_region(middle, end);
        } else
            fwrite(baseline, 1, size, out);
    }
    free(baseline);
}

/* Promotion produces chains of copies between the same scalar types.
 * Resolve those before use counting so the allocator sees real consumers. */
static Ref
copy_source(Ref ref)
{
    for (unsigned remaining = fn->ntmp; rtype(ref) == RTmp && remaining--; ) {
        Tmp *tmp = &fn->tmp[ref.val];
        Ins *i = tmp->def;
        if (!i || tmp->ndef != 1 || i->op != Ocopy || i->cls > Kl)
            break;
        Ref arg = i->arg[0];
        if (rtype(arg) == RTmp && fn->tmp[arg.val].cls == i->cls)
            ref = arg;
        else if (rtype(arg) == RCon && fn->con[arg.val].type == CBits &&
                 !fn->con[arg.val].flt &&
                 (i->cls == Kl || (uint64_t)fn->con[arg.val].bits.i <= UINT32_MAX))
            return arg;
        else
            break;
    }
    return ref;
}

static int
pure_integer(const Ins *i)
{
    if (i->cls > Kl)
        return 0;
    return INRANGE(i->op, Ocmpw, Ocmpl1) || isext(i->op) ||
           i->op == Ocopy || i->op == Oneg ||
           i->op == Oadd || i->op == Osub || i->op == Omul ||
           i->op == Oand || i->op == Oor || i->op == Oxor ||
           i->op == Oshl || i->op == Oshr || i->op == Osar;
}

static int
plain_constant(Ref ref)
{
    if (rtype(ref) != RCon)
        return 0;
    Con *c = &fn->con[ref.val];
    return c->type == CBits && !c->flt;
}

static int
reduce_multiply(Ins *ins)
{
    if (ins->op != Omul || ins->cls > Kl)
        return 0;
    unsigned constant = plain_constant(ins->arg[0]) ? 0 : 1;
    Ref factor = ins->arg[constant];
    Ref input = ins->arg[!constant];
    if (!plain_constant(factor) || (rtype(input) != RTmp && !plain_constant(input)))
        return 0;
    uint64_t value = fn->con[factor.val].bits.i;
    if (ins->cls == Kw)
        value = (uint32_t)value;
    if (value > 1 && (value & (value - 1)))
        return 0;
    if (value <= 1) {
        ins->op = Ocopy;
        ins->arg[0] = value ? input : getcon(0, fn);
        ins->arg[1] = R;
    } else {
        unsigned shift = 0;
        for (; value > 1; value >>= 1)
            ++shift;
        ins->op = Oshl;
        ins->arg[0] = input;
        ins->arg[1] = getcon(shift, fn);
    }
    return 1;
}

static int
reduce_extension(Ins *ins)
{
    if (!isext(ins->op) || rtype(ins->arg[0]) != RTmp)
        return 0;
    const Tmp *arg = &fn->tmp[ins->arg[0].val];
    int from = arg->width - Wsb;
    int to = ins->op - Oextsb;
    if (arg->ndef != 1 || arg->cls != ins->cls || from < 0 || from > to || ((from ^ to) & 1))
        return 0;
    ins->op = Ocopy;
    return 1;
}

static int
reduce_identity(Ins *i)
{
    if (i->cls > Kl)
        return 0;
    Ref value = i->arg[0], constant = i->arg[1];
    switch (i->op) {
    case Oadd: case Oand: case Oor: case Oxor:
        if (plain_constant(value)) {
            value = i->arg[1];
            constant = i->arg[0];
        }
        break;
    case Osub: case Oshl: case Oshr: case Osar:
        break;
    default:
        return 0;
    }
    if (!plain_constant(constant))
        return 0;
    uint64_t bits = fn->con[constant.val].bits.i;
    uint64_t mask = i->cls == Kw ? UINT32_MAX : UINT64_MAX;
    if (i->op == Oshl || i->op == Oshr || i->op == Osar)
        mask = i->cls == Kw ? 31 : 63;
    if ((bits & mask) != (i->op == Oand ? mask : 0))
        return 0;
    i->op = Ocopy;
    i->arg[0] = value;
    i->arg[1] = R;
    return 1;
}

static void
simplify_values(void)
{
    int changed;
    do {
        changed = 0;
        for (Blk *b = fn->start; b; b = b->link) {
            for (Ins *i = b->ins; i < b->ins + b->nins; ++i) {
                for (unsigned n = 0; n < 2; ++n)
                    i->arg[n] = copy_source(i->arg[n]);
                changed |= reduce_identity(i) || reduce_multiply(i) || reduce_extension(i);
                if (!pure_integer(i) || i->op == Ocopy ||
                    !plain_constant(i->arg[0]) ||
                    (!req(i->arg[1], R) && !plain_constant(i->arg[1])))
                    continue;
                Ref folded = foldref(fn, i);
                if (!req(folded, R)) {
                    i->op = Ocopy;
                    i->arg[0] = i->cls == Kw ? getcon((uint32_t)fn->con[folded.val].bits.i, fn) : folded;
                    i->arg[1] = R;
                    changed = 1;
                }
            }
            for (Phi *p = b->phi; p; p = p->link)
                for (unsigned n = 0; n < p->narg; ++n)
                    p->arg[n] = copy_source(p->arg[n]);
            b->jmp.arg = copy_source(b->jmp.arg);
            if (b->jmp.type == Jjnz && (b->s1 == b->s2 || plain_constant(b->jmp.arg))) {
                if (b->s1 != b->s2 && !(uint32_t)fn->con[b->jmp.arg.val].bits.i)
                    b->s1 = b->s2;
                b->s2 = NULL;
                b->jmp.type = Jjmp;
                b->jmp.arg = R;
                changed = 1;
            }
        }
        fillcfg(fn);
        filluse(fn);
        for (Blk *b = fn->start; b; b = b->link)
            for (Ins *i = b->ins; i < b->ins + b->nins; ++i)
                if (pure_integer(i) && rtype(i->to) == RTmp && !fn->tmp[i->to.val].nuse &&
                    /* Preserve diagnostics for references the backend must resolve. */
                    (rtype(i->arg[0]) == RTmp || plain_constant(i->arg[0])) &&
                    (req(i->arg[1], R) || rtype(i->arg[1]) == RTmp || plain_constant(i->arg[1]))) {
                    *i = (Ins){.op = Onop};
                    changed = 1;
                }
        if (changed)
            filluse(fn);
    } while (changed);
}

typedef struct {
    Ref value;
    uint64_t constant;
    unsigned bits;
    int cmp;
} BranchFact;

static BranchFact
comparison_fact(Ref condition, unsigned block_id, int taken)
{
    if (rtype(condition) != RTmp || condition.val < Tmp0)
        return (BranchFact){0};
    const Tmp *cond = &fn->tmp[condition.val];
    const Ins *i = cond->def;
    if (!i || cond->ndef != 1 || cond->bid != block_id ||
        (!INRANGE(i->op, Ocmpw, Ocmpw1) && !INRANGE(i->op, Ocmpl, Ocmpl1)))
        return (BranchFact){0};
    unsigned bits = i->op < Ocmpl ? 32 : 64;
    int op = taken ? i->op : cmpwlneg(i->op);
    int cmp = op - (bits == 32 ? Ocmpw : Ocmpl);
    Ref value = i->arg[0], constant = i->arg[1];
    if (plain_constant(value)) {
        value = i->arg[1];
        constant = i->arg[0];
        cmp = cmpop(cmp);
    }
    if (rtype(value) != RTmp || value.val < Tmp0 || fn->tmp[value.val].ndef != 1 ||
        !plain_constant(constant))
        return (BranchFact){0};
    uint64_t c = fn->con[constant.val].bits.i;
    return (BranchFact){value, bits == 32 ? (uint32_t)c : c, bits, cmp};
}

static BranchFact
branch_fact(const Blk *b, int taken)
{
    return b->jmp.type == Jjnz ? comparison_fact(b->jmp.arg, b->id, taken) : (BranchFact){0};
}

static int
signed_fact(BranchFact fact)
{
    return INRANGE(fact.cmp, Cisge, Cislt);
}

typedef struct {
    uint64_t lo, hi;
} BranchRange;

static int
restrict_range(BranchRange *range, BranchFact fact, int sign)
{
    uint64_t c = fact.constant;
    if (sign)
        c ^= UINT64_C(1) << (fact.bits - 1);
    uint64_t lo = range->lo, hi = range->hi;
    switch (fact.cmp) {
    case Cieq:
        if (c < lo || c > hi)
            return 0;
        lo = hi = c;
        break;
    case Cine:
        if (lo == c && hi == c)
            return 0;
        if (lo == c)
            ++lo;
        if (hi == c)
            --hi;
        break;
    case Cisge: case Ciuge:
        if (lo < c)
            lo = c;
        break;
    case Cisgt: case Ciugt:
        if (hi <= c)
            return 0;
        if (lo <= c)
            lo = c + 1;
        break;
    case Cisle: case Ciule:
        if (hi > c)
            hi = c;
        break;
    case Cislt: case Ciult:
        if (lo >= c)
            return 0;
        if (hi >= c)
            hi = c - 1;
        break;
    }
    *range = (BranchRange){lo, hi};
    return lo <= hi;
}

/* Small finite domains preserve holes in phi-merged state values. An
 * unsupported value uses all bits as the unknown sentinel. */
static uint64_t
constant_domain(Ref ref, const uint64_t *domains)
{
    if (rtype(ref) == RTmp && ref.val >= Tmp0)
        return domains[ref.val];
    if (!plain_constant(ref))
        return UINT64_MAX;
    uint64_t c = fn->con[ref.val].bits.i;
    return c < 64 ? UINT64_C(1) << c : UINT64_MAX;
}

static void
branch_domains(uint64_t *domains)
{
    for (int t = Tmp0; t < fn->ntmp; ++t) {
        const Tmp *tmp = &fn->tmp[t];
        domains[t] = tmp->ndef != 1 || tmp->cls > Kl ||
                     (tmp->def && tmp->def->op != Ocopy) ? UINT64_MAX : 0;
    }
    int changed;
    do {
        changed = 0;
        for (Blk *b = fn->start; b; b = b->link) {
            for (Phi *p = b->phi; p; p = p->link) {
                uint64_t old = domains[p->to.val];
                for (unsigned n = 0; n < p->narg; ++n)
                    domains[p->to.val] |= constant_domain(p->arg[n], domains);
                changed |= old != domains[p->to.val];
            }
            for (Ins *i = b->ins; i < b->ins + b->nins; ++i)
                if (i->op == Ocopy && !req(i->to, R)) {
                    uint64_t old = domains[i->to.val];
                    domains[i->to.val] |= constant_domain(i->arg[0], domains);
                    changed |= old != domains[i->to.val];
                }
        }
    } while (changed);
}

static int
fact_accepts(BranchFact fact, unsigned value)
{
    int sign = signed_fact(fact);
    uint64_t rank = sign ? value ^ (UINT64_C(1) << (fact.bits - 1)) : value;
    BranchRange range = {rank, rank};
    return restrict_range(&range, fact, sign);
}

static int
known_branch(Blk *b, BranchFact *facts, const uint64_t *domains)
{
    BranchFact test = branch_fact(b, 1);
    if (!test.bits)
        return 0;
    unsigned def = fn->tmp[test.value.val].bid;
    unsigned count = 0;
    for (Blk *at = b; at->id != def && at->npred == 1;) {
        Blk *prev = at->pred[0];
        if (prev->id >= at->id)
            break;
        if (prev->s1 != prev->s2) {
            BranchFact fact = branch_fact(prev, prev->s1 == at);
            if (fact.bits == test.bits && req(fact.value, test.value))
                facts[count++] = fact;
        }
        at = prev;
    }
    uint64_t domain = domains[test.value.val];
    if (domain && domain != UINT64_MAX) {
        int yes = 0, no = 0;
        for (unsigned value = 0; value < 64; ++value) {
            if (!(domain & (UINT64_C(1) << value)))
                continue;
            unsigned n = 0;
            while (n < count && fact_accepts(facts[n], value))
                ++n;
            if (n == count) {
                if (fact_accepts(test, value))
                    yes = 1;
                else
                    no = 1;
            }
        }
        return yes == no ? 0 : yes ? 1 : 2;
    }
    /* Equality can use either ordering. Ordered bounds only combine with
     * comparisons of the same signedness and width. */
    int sign = signed_fact(test);
    if (test.cmp == Cieq || test.cmp == Cine)
        for (unsigned n = 0; n < count; ++n)
            if (facts[n].cmp != Cieq && facts[n].cmp != Cine) {
                sign = signed_fact(facts[n]);
                break;
            }
    BranchRange range = {0, test.bits == 32 ? UINT32_MAX : UINT64_MAX};
    while (count) {
        BranchFact fact = facts[--count];
        if ((fact.cmp == Cieq || fact.cmp == Cine || signed_fact(fact) == sign) &&
            !restrict_range(&range, fact, sign))
            return 0;
    }
    BranchRange other = range;
    int yes = restrict_range(&range, test, sign);
    int no = restrict_range(&other, branch_fact(b, 0), sign);
    return yes == no ? 0 : yes ? 1 : 2;
}

static void
fold_known_branches(void)
{
    BranchFact *facts = alloc(fn->nblk * sizeof *facts);
    unsigned char *choice = alloc(fn->nblk);
    uint64_t *domains = alloc(fn->ntmp * sizeof *domains);
    int changed;
    do {
        branch_domains(domains);
        changed = 0;
        for (Blk *b = fn->start; b; b = b->link) {
            choice[b->id] = known_branch(b, facts, domains);
            changed |= choice[b->id];
        }
        if (!changed)
            break;
        for (Blk *b = fn->start; b; b = b->link)
            if (choice[b->id]) {
                if (choice[b->id] == 2)
                    b->s1 = b->s2;
                b->s2 = NULL;
                b->jmp.type = Jjmp;
                b->jmp.arg = R;
            }
        fillcfg(fn);
        filluse(fn);
        simplify_values();
        simplcfg(fn);
        filluse(fn);
    } while (changed);
}

static int
same_range_value(Ref a, Ref b)
{
    if (req(a, b))
        return 1;
    const Ins *lhs = fn->tmp[a.val].def, *rhs = fn->tmp[b.val].def;
    return lhs && rhs && isext(lhs->op) && lhs->op == rhs->op &&
           lhs->cls == rhs->cls && req(lhs->arg[0], rhs->arg[0]);
}

static int
fold_range_and(Blk *b)
{
    Ins *code = NULL;
    unsigned count = 0;
    for (unsigned n = 0; n < b->nins; ++n) {
        Ins *i = &b->ins[n];
        int combined = 0;
        if (i->op == Oand && i->cls == Kw) {
            BranchFact lo = comparison_fact(i->arg[0], b->id, 1);
            BranchFact hi = comparison_fact(i->arg[1], b->id, 1);
            if (lo.cmp == Cisle || lo.cmp == Ciule) {
                BranchFact swap = lo;
                lo = hi;
                hi = swap;
            }
            int sign = lo.cmp == Cisge;
            if (lo.bits && lo.bits == hi.bits && (sign || lo.cmp == Ciuge) &&
                hi.cmp == (sign ? Cisle : Ciule) && same_range_value(lo.value, hi.value)) {
                uint64_t bias = sign ? UINT64_C(1) << (lo.bits - 1) : 0;
                if ((lo.constant ^ bias) <= (hi.constant ^ bias)) {
                    if (!code) {
                        code = vnew(0, sizeof *code, PFn);
                        for (unsigned p = 0; p < n; ++p)
                            addins(&code, &count, &b->ins[p]);
                    }
                    /* Modular subtraction measures distance from the lower
                     * bound even when the signed interval crosses zero. */
                    int cls = lo.bits == 32 ? Kw : Kl;
                    Ref delta = newtmp("range", cls, fn);
                    uint64_t span = hi.constant - lo.constant;
                    if (cls == Kw)
                        span = (uint32_t)span;
                    addins(&code, &count, &(Ins){.op = Osub, .cls = cls, .to = delta,
                                                .arg = {lo.value, getcon(lo.constant, fn)}});
                    addins(&code, &count, &(Ins){.op = cls == Kw ? Oculew : Oculel, .cls = Kw,
                                                .to = i->to, .arg = {delta, getcon(span, fn)}});
                    combined = 1;
                }
            }
        }
        if (code && !combined)
            addins(&code, &count, i);
    }
    if (!code)
        return 0;
    b->ins = code;
    b->nins = count;
    return 1;
}

static int
empty_arm(Blk *b)
{
    if (b->npred != 1 || b->phi || b->jmp.type != Jjmp)
        return 0;
    for (unsigned n = 0; n < b->nins; ++n)
        if (b->ins[n].op != Onop && b->ins[n].op != Odbgloc)
            return 0;
    return 1;
}

static int
fold_boolean_diamond(Blk *b)
{
    if (b->jmp.type != Jjnz || b->s1 == b->s2 || !empty_arm(b->s1) ||
        !empty_arm(b->s2) || b->s1->s1 != b->s2->s1)
        return 0;
    Blk *join = b->s1->s1;
    Phi *p = join->phi;
    if (join->npred != 2 || !p || p->link || p->cls != Kw || p->narg != 2)
        return 0;
    Ref yes = phiarg(p, b->s1), no = phiarg(p, b->s2);
    if (!plain_constant(yes) || !plain_constant(no))
        return 0;
    uint32_t t = fn->con[yes.val].bits.i, f = fn->con[no.val].bits.i;
    if (t > 1 || f > 1 || t == f)
        return 0;
    Ref condition = b->jmp.arg;
    const Ins *def = rtype(condition) == RTmp ? fn->tmp[condition.val].def : NULL;
    int boolean = def && fn->tmp[condition.val].ndef == 1 &&
                  INRANGE(def->op, Ocmpw, Ocmpl1);
    Ins *code = vnew(0, sizeof *code, PFn);
    unsigned count = 0;
    int op = t ? Ocnew : Oceqw;
    if (t && boolean)
        op = Ocopy;
    addins(&code, &count, &(Ins){.op = op, .cls = Kw, .to = p->to,
                                .arg = {condition, op == Ocopy ? R : getcon(0, fn)}});
    for (unsigned n = 0; n < join->nins; ++n)
        addins(&code, &count, &join->ins[n]);
    join->phi = NULL;
    join->ins = code;
    join->nins = count;
    b->jmp.type = Jjmp;
    b->jmp.arg = R;
    b->s1 = join;
    b->s2 = NULL;
    return 1;
}

static void
simplify_booleans(void)
{
    int changed = 0;
    for (Blk *b = fn->start; b; b = b->link)
        changed |= fold_range_and(b);
    if (changed)
        filluse(fn);
    for (Blk *b = fn->start; b; b = b->link)
        changed |= fold_boolean_diamond(b);
    if (changed) {
        fillcfg(fn);
        filluse(fn);
        simplify_values();
        simplcfg(fn);
        filluse(fn);
    }
}

static Ref
substitute(Ref value, const Ref *replacement, int count)
{
    if (rtype(value) == RTmp && value.val < (unsigned)count && !req(replacement[value.val], R))
        return replacement[value.val];
    return value;
}

/* Rotate a two-block loop. The test is private to the branch, and the only
 * path from the loop to an external use of a carried value is its exit. */
static int
rotate_loop(Blk *header)
{
    Blk *body = header->s1, *exit = header->s2;
    if (!header->phi || header->jmp.type != Jjnz || header->npred != 2 ||
        body == header || exit == header || body == exit || body->phi ||
        body->npred != 1 || body->jmp.type != Jjmp || body->s1 != header ||
        exit->npred != 1 || exit->phi)
        return 0;
    Blk *entry = header->pred[header->pred[0] == body];
    if (entry == header || entry == body || entry->jmp.type != Jjmp)
        return 0;
    for (Ins *i = body->ins; i < body->ins + body->nins; ++i)
        if (i->op != Onop && i->op != Odbgloc && !pure_integer(i))
            return 0;
    for (Ins *i = header->ins; i < header->ins + header->nins; ++i) {
        if (i->op == Onop || i->op == Odbgloc)
            continue;
        if (!pure_integer(i))
            return 0;
        Tmp *t = &fn->tmp[i->to.val];
        for (unsigned n = 0; n < t->nuse; ++n)
            if (t->use[n].bid != header->id || t->use[n].type == UPhi)
                return 0;
    }
    unsigned carried = 0;
    for (Phi *p = header->phi; p; p = p->link) {
        if (++carried > 2 || p->narg != 2 || p->cls > Kl)
            return 0;
        for (unsigned n = 0; n < 2; ++n) {
            Ref arg = p->arg[n];
            if (p->cls == Kw && !plain_constant(arg) &&
                (rtype(arg) != RTmp || fn->tmp[arg.val].cls != Kw))
                return 0;
        }
    }
    /* The entry test and the next-iteration test see different values.
     * Substitution is simultaneous because back-edge phi inputs may cycle. */
    int count = fn->ntmp;
    Ref *initial = alloc(count * sizeof *initial);
    Ref *updated = alloc(count * sizeof *updated);
    Ref *outside = alloc(count * sizeof *outside);
    Phi *exit_phis = NULL;
    for (Phi *p = header->phi; p; p = p->link) {
        unsigned start = p->blk[0] != entry;
        initial[p->to.val] = p->arg[start];
        updated[p->to.val] = p->arg[1 - start];
        if (p->cls == Kw) {
            Ref *args[] = {&initial[p->to.val], &updated[p->to.val]};
            for (unsigned n = 0; n < 2; ++n)
                if (plain_constant(*args[n]))
                    *args[n] = getcon((uint32_t)fn->con[args[n]->val].bits.i, fn);
        }
        p->blk[start] = header;
        p->arg[start] = initial[p->to.val];
        p->arg[1 - start] = updated[p->to.val];
        Tmp *tmp = &fn->tmp[p->to.val];
        int needed = 0;
        for (unsigned n = 0; n < tmp->nuse; ++n)
            needed |= tmp->use[n].bid != header->id && tmp->use[n].bid != body->id;
        if (needed) {
            Phi *join = alloc(sizeof *join);
            join->to = newtmp(tmp->name, p->cls, fn);
            join->cls = p->cls;
            join->narg = 2;
            join->arg = alloc(2 * sizeof *join->arg);
            join->blk = alloc(2 * sizeof *join->blk);
            join->arg[0] = initial[p->to.val];
            join->arg[1] = updated[p->to.val];
            join->blk[0] = header;
            join->blk[1] = body;
            join->link = exit_phis;
            exit_phis = join;
            outside[p->to.val] = join->to;
        }
    }
    for (Blk *b = fn->start; b; b = b->link) {
        if (b == header || b == body)
            continue;
        for (Ins *i = b->ins; i < b->ins + b->nins; ++i)
            for (unsigned n = 0; n < 2; ++n)
                i->arg[n] = substitute(i->arg[n], outside, count);
        for (Phi *p = b->phi; p; p = p->link)
            for (unsigned n = 0; n < p->narg; ++n)
                p->arg[n] = substitute(p->arg[n], outside, count);
        b->jmp.arg = substitute(b->jmp.arg, outside, count);
    }
    exit->phi = exit_phis;
    for (Ins *i = header->ins; i < header->ins + header->nins; ++i) {
        if (i->op == Onop || i->op == Odbgloc)
            continue;
        Ins clone = *i;
        for (unsigned n = 0; n < 2; ++n) {
            clone.arg[n] = substitute(i->arg[n], updated, count);
            i->arg[n] = substitute(i->arg[n], initial, count);
        }
        clone.to = newtmp(fn->tmp[i->to.val].name, i->cls, fn);
        updated[i->to.val] = clone.to;
        addins(&body->ins, &body->nins, &clone);
    }
    body->phi = header->phi;
    header->phi = NULL;
    body->jmp.type = Jjnz;
    body->jmp.arg = substitute(header->jmp.arg, updated, count);
    body->s1 = body;
    body->s2 = exit;
    header->jmp.arg = substitute(header->jmp.arg, initial, count);
    return 1;
}

static void
promote_locals(void)
{
    fillcfg(fn);
    filluse(fn);
    promote(fn);
    filluse(fn);
    ssa(fn);
    filluse(fn);
    fillalias(fn);
    loadopt(fn);
    filluse(fn);
    simplify_values();
    simplcfg(fn);
    filluse(fn);
    simplify_booleans();
}

static void
mark_function_address(const char *name)
{
    Symbol *s = find_symbol(name);
    if (s && s->function)
        s->address_taken = 1;
}

static void
mark_address_ref(Ref ref)
{
    if (rtype(ref) == RCon && fn->con[ref.val].type == CAddr)
        mark_function_address(str(fn->con[ref.val].sym.id));
}

static void
find_address_taken(void)
{
    for (Blk *b = fn->start; b; b = b->link) {
        mark_address_ref(b->jmp.arg);
        for (Phi *p = b->phi; p; p = p->link)
            for (unsigned n = 0; n < p->narg; ++n)
                mark_address_ref(p->arg[n]);
        for (Ins *i = b->ins; i < b->ins + b->nins; ++i) {
            if (i->op != Ocall)
                mark_address_ref(i->arg[0]);
            mark_address_ref(i->arg[1]);
        }
    }
}

static int
narrow_alignment(Ref ref, unsigned alignment)
{
    if (tmp_alignment[ref.val] <= alignment)
        return 0;
    tmp_alignment[ref.val] = alignment;
    return 1;
}

static void
compute_alignment(const Symbol *s, const unsigned char *assumed)
{
    if (!tmp_alignment)
        tmp_alignment = alloc(fn->ntmp);
    for (int t = Tmp0; t < fn->ntmp; ++t)
        tmp_alignment[t] = fn->tmp[t].ndef == 1 ? 8 : 1;
    unsigned n = 0;
    for (Ins *i = fn->start->ins; i < fn->start->ins + fn->start->nins && ispar(i->op); ++i, ++n) {
        unsigned align = !s->address_taken && i->op == Opar ? s->param_align[n] : 1;
        if (assumed && assumed[n] > align)
            align = assumed[n];
        tmp_alignment[i->to.val] = align;
    }

    /* A loop-carried address keeps its alignment if both the incoming
     * value and the backedge preserve it. Weaken facts to a fixed point. */
    int changed;
    do {
        changed = 0;
        for (Blk *b = fn->start; b; b = b->link) {
            for (Phi *p = b->phi; p; p = p->link)
                for (unsigned a = 0; a < p->narg; ++a)
                    changed |= narrow_alignment(p->to, ref_alignment(p->arg[a]));
            for (Ins *i = b->ins; i < b->ins + b->nins; ++i)
                if (!req(i->to, R) && !ispar(i->op))
                    changed |= narrow_alignment(i->to, operation_alignment(i));
        }
    } while (changed);
}

/* Start at the maximum useful alignment. Each call can only weaken a fact,
 * including when an argument is forwarded through a recursive call. */
static void
infer_parameter_alignment(Symbol *caller)
{
    if (!caller->calls)
        return;
    promote_locals();
    compute_alignment(caller, NULL);
    for (Blk *b = fn->start; b; b = b->link) {
        Ins *args = NULL;
        for (Ins *i = b->ins; i < b->ins + b->nins; ++i) {
            if (isarg(i->op)) {
                if (!args)
                    args = i;
                continue;
            }
            if (i->op == Ocall && rtype(i->arg[0]) == RCon) {
                Symbol *callee = call_target(i->arg[0]);
                if (!callee->address_taken) {
                    unsigned nargs = args ? (unsigned)(i - args) : 0;
                    for (unsigned n = 0; n < callee->nparam; ++n) {
                        unsigned alignment = n < nargs && args[n].op == Oarg ?
                                             ref_alignment(args[n].arg[0]) : 1;
                        if (alignment < callee->param_align[n]) {
                            callee->param_align[n] = alignment;
                            alignment_changed = 1;
                        }
                    }
                }
            }
            args = NULL;
        }
    }
}

/* A small, straight-line leaf can be scheduled in the caller's SSA region. */
static void
collect_inline_body(Symbol *symbol)
{
    if (symbol->calls || symbol->indirect || fn->vararg || fn->retty >= 0)
        return;
    promote_locals();
    Blk *b = fn->start;
    if (b->link || b->phi || (b->jmp.type != Jretw && b->jmp.type != Jretl))
        return;
    InlineBody body = {.ntmp = fn->ntmp, .cls = b->jmp.type == Jretw ? Kw : Kl,
                       .result = b->jmp.arg};
    if (rtype(body.result) != RTmp && !plain_constant(body.result))
        return;
    for (Ins *i = b->ins; i < b->ins + b->nins; ++i) {
        if (i->op == Onop || i->op == Odbgloc)
            continue;
        if (i->op == Opar && i->cls <= Kl && body.nparam < INLINE_ARGS) {
            body.param[body.nparam++] = *i;
            continue;
        }
        if (!pure_integer(i) || body.nins == INLINE_OPS)
            return;
        for (unsigned n = 0; n < 2; ++n)
            if (!req(i->arg[n], R) && rtype(i->arg[n]) != RTmp && !plain_constant(i->arg[n]))
                return;
        body.ins[body.nins++] = *i;
    }
    symbol->body = emalloc(sizeof body + fn->ncon * sizeof(Con));
    *symbol->body = body;
    memcpy(symbol->body->con, fn->con, fn->ncon * sizeof(Con));
}

static Ref
inline_operand(const InlineBody *body, const Ref *temps, Ref operand)
{
    if (req(operand, R))
        return R;
    if (rtype(operand) == RTmp)
        return temps[operand.val];
    return getcon(body->con[operand.val].bits.i, fn);
}

static int
inline_call(Ins **out, unsigned *count, Ins *args, Ins *call)
{
    if (req(call->to, R) || rtype(call->arg[0]) != RCon)
        return 0;
    const InlineBody *body = call_target(call->arg[0])->body;
    if (!body || call->cls != body->cls || call - args != body->nparam)
        return 0;
    for (unsigned n = 0; n < body->nparam; ++n)
        if (args[n].op != Oarg || args[n].cls != body->param[n].cls)
            return 0;

    Ref *temps = alloc(body->ntmp * sizeof *temps);
    for (unsigned n = 0; n < body->nparam; ++n) {
        Ref arg = newtmp("inl", args[n].cls, fn);
        temps[body->param[n].to.val] = arg;
        addins(out, count, &(Ins){.op = Ocopy, .cls = args[n].cls, .to = arg,
                                 .arg = {args[n].arg[0], R}});
    }
    for (unsigned n = 0; n < body->nins; ++n) {
        Ins ins = body->ins[n];
        Ref dst = newtmp("inl", ins.cls, fn);
        for (unsigned a = 0; a < 2; ++a)
            ins.arg[a] = inline_operand(body, temps, ins.arg[a]);
        temps[ins.to.val] = dst;
        ins.to = dst;
        addins(out, count, &ins);
    }
    addins(out, count, &(Ins){.op = Ocopy, .cls = call->cls, .to = call->to,
                             .arg = {inline_operand(body, temps, body->result), R}});
    return 1;
}

static void
inline_calls(void)
{
    int changed = 0;
    for (Blk *b = fn->start; b; b = b->link) {
        Ins *end = b->ins + b->nins;
        Ins *first_call = b->ins;
        while (first_call < end && first_call->op != Ocall)
            ++first_call;
        if (first_call == end)
            continue;
        Ins *ins = vnew(0, sizeof(Ins), PFn);
        unsigned count = 0;
        int inlined = 0;
        for (Ins *i = b->ins; i < end;) {
            Ins *call = i;
            while (call < end && isarg(call->op))
                ++call;
            if (call < end && call->op == Ocall) {
                if (inline_call(&ins, &count, i, call)) {
                    inlined = 1;
                    i = call + 1;
                } else {
                    while (i <= call)
                        addins(&ins, &count, i++);
                }
            } else {
                addins(&ins, &count, i);
                ++i;
            }
        }
        if (inlined) {
            b->ins = ins;
            b->nins = count;
            changed = 1;
        }
    }
    if (changed) {
        filluse(fn);
        simplify_values();
        simplcfg(fn);
        filluse(fn);
    }
}

static void
rotate_loops(void)
{
    for (Blk *b = fn->start; b; b = b->link)
        if (rotate_loop(b)) {
            fillcfg(fn);
            filluse(fn);
        }
    simplcfg(fn);
    filluse(fn);
    simplify_values();
}

static Ref
incoming_value(Phi *phi, Blk *from)
{
    for (unsigned n = 0; n < phi->narg; ++n)
        if (phi->blk[n] == from)
            return phi->arg[n];
    return R;
}

static int
is_constant(Ref ref, uint32_t value)
{
    return plain_constant(ref) && (uint32_t)fn->con[ref.val].bits.i == value;
}

static int
countdown_function(const Symbol *symbol)
{
    Blk *entry = fn->start, *header = entry->s1;
    if (entry->jmp.type != Jjmp || !header || header->jmp.type != Jjnz ||
        header->npred != 2 || !header->phi || !header->phi->link || header->phi->link->link)
        return 0;
    Blk *body = header->s1, *exit = header->s2;
    if (body == entry || exit == entry || body == header || exit == header || body == exit ||
        body->phi || exit->phi || body->npred != 1 || exit->npred != 1 ||
        body->jmp.type != Jjmp || body->s1 != header || exit->jmp.type != Jretw)
        return 0;

    Ref params[2] = {R, R};
    unsigned nargs = 0;
    for (Ins *i = entry->ins; i < entry->ins + entry->nins; ++i) {
        if (i->op == Onop || i->op == Odbgloc)
            continue;
        if (nargs == 2 || i->op != Opar || i->cls != Kw)
            return 0;
        params[nargs++] = i->to;
    }
    if (!nargs)
        return 0;
    Phi *sum = header->phi, *count = sum->link;
    if (!req(sum->to, exit->jmp.arg)) {
        count = sum;
        sum = sum->link;
    }
    if (!req(sum->to, exit->jmp.arg) || sum->cls != Kw || count->cls != Kw ||
        !req(incoming_value(count, entry), params[0]))
        return 0;
    Ref seed = incoming_value(sum, entry);
    int seed_arg = nargs == 2;
    if (seed_arg ? !req(seed, params[1]) : !plain_constant(seed))
        return 0;

    Ref test = count->to;
    for (Ins *i = header->ins; i < header->ins + header->nins; ++i) {
        if (i->op == Onop || i->op == Odbgloc)
            continue;
        if (!req(test, count->to) || i->op != Ocmpw + Cine ||
            !((req(i->arg[0], count->to) && is_constant(i->arg[1], 0)) ||
              (req(i->arg[1], count->to) && is_constant(i->arg[0], 0))))
            return 0;
        test = i->to;
    }
    if (!req(test, header->jmp.arg))
        return 0;
    for (Ins *i = exit->ins; i < exit->ins + exit->nins; ++i)
        if (i->op != Onop && i->op != Odbgloc)
            return 0;

    Ref next = incoming_value(count, body), accumulated = incoming_value(sum, body);
    int updates = 0;
    for (Ins *i = body->ins; i < body->ins + body->nins; ++i) {
        if (i->op == Onop || i->op == Odbgloc)
            continue;
        if (i->cls != Kw)
            return 0;
        if (req(i->to, next) && i->op == Osub && req(i->arg[0], count->to) &&
            is_constant(i->arg[1], 1))
            updates |= 1;
        else if (req(i->to, accumulated) && i->op == Oadd &&
                 ((req(i->arg[0], sum->to) && req(i->arg[1], count->to)) ||
                  (req(i->arg[1], sum->to) && req(i->arg[0], count->to))))
            updates |= 2;
        else
            return 0;
    }
    if (updates != 3)
        return 0;
    /* The extra zero iteration leaves the sum unchanged. Its decrement is
     * drained on exit, and word normalization is only needed at the ABI. */
    char *loop = alloc(strlen(symbol->label) + sizeof "_countdown");
    sprintf(loop, "%s_countdown", symbol->label);
    return schedule_countdown(out, symbol->label, loop,
                              seed_arg ? 0 : (uint32_t)fn->con[seed.val].bits.i, seed_arg);
}

static void
blit(Ins *i, unsigned bytes)
{
    for (unsigned n = 0; n < bytes; ++n) {
        value(i->arg[0], "ARITH_A.LHS");
        number(n, "ARITH_A.RHS");
        typed_load("ARITH_A.ADD", 0, B);
        value(i->arg[1], "ARITH_A.LHS");
        number(n, "ARITH_A.RHS");
        typed_store("ARITH_A.ADD", B, 0);
    }
}

static void
edge_label(const Symbol *f, Blk *from, Blk *to)
{
    if (to->phi)
        fprintf(out, "%s_e%u_%u", f->label, from->id, to->id);
    else
        fprintf(out, "%s_b%u", f->label, to->id);
}

static void
edge(const Symbol *f, Blk *from, Blk *to)
{
    if (!to || !to->phi)
        return;
    edge_label(f, from, to);
    line(":");
    size_t offset = phi_base;
    for (Phi *p = to->phi; p; p = p->link, offset += 8) {
        unsigned n;
        for (n = 0; n < p->narg && p->blk[n] != from; ++n)
            ;
        if (n == p->narg || p->cls > Kl)
            error("unsupported phi");
        value(p->arg[n], D);
        if (p->cls == Kw)
            extend(D, D, 32, 0);
        store_frame(offset, D);
    }
    offset = phi_base;
    for (Phi *p = to->phi; p; p = p->link, offset += 8) {
        load_frame(offset, D);
        store_frame(slot(p->to), D);
    }
    line("CONST -> PC_REL [rel=%s_b%u]", f->label, to->id);
}

static void
jump(const Symbol *f)
{
    int op = block->jmp.type;
    if (op == Jhlt) {
        literal("3", "PC");
    } else if (op == Jjmp || op == Jjnz) {
        if (op == Jjnz) {
            value(block->jmp.arg, D);
            extend(D, "COND", 32, 0);
            fputs("CONST -> PC_REL [pred, rel=", out);
            edge_label(f, block, block->s1);
            line("]");
        }
        fputs("CONST -> PC_REL [rel=", out);
        edge_label(f, block, op == Jjnz ? block->s2 : block->s1);
        line("]");
    } else if (op == Jret0 || op == Jretw || op == Jretl || isretbh(op)) {
        if (op != Jret0) {
            value(block->jmp.arg, D);
            if (isretbh(op)) {
                unsigned n = op - Jretsb;
                extend(D, D, n < 2 ? 8 : 16, !(n & 1));
            }
            if (op != Jretl)
                extend(D, D, 32, 0);
            if (!optimize)
                store_global(RESULT, D);
        }
        if (optimize) {
            address(0, A);
            store_global(SP, A);
            line("STACK_B.TOP -> PC, %s -> " A " [sync]", op == Jret0 ? "ZERO" : D);
            return;
        }
        load_frame(0, A);
        address(0, D);
        store_global(SP, D);
        move(A, "PC");
    } else {
        error("unsupported return or jump");
    }
}

static size_t align_up(size_t n, size_t alignment);

static int
flow_barrier(Ins *i)
{
    return i->op == Odiv || i->op == Orem || i->op == Oudiv || i->op == Ourem ||
           i->op == Oblit0;
}

static int
flow_rematerialize(int temp)
{
    Ins *def = fn->tmp[temp].def;
    return def && def->op == Ocopy && rtype(def->arg[0]) == RCon &&
           !fn->con[def->arg[0].val].flt;
}

typedef struct FlowSite FlowSite;
struct FlowSite {
    FlowSite *next;
    Ins *instruction;
    BSet live[1];
    int saved[8], count;
};

static void
flow_spill(int temp)
{
    if (!fifo_spill[temp]) {
        frame_size = align_up(frame_size, 8);
        fifo_spill[temp] = frame_size + 1;
        frame_size += 8;
    }
}

static FlowSite *
flow_sites(void)
{
    FlowSite *sites = NULL;
    BSet live[1];
    bsinit(live, fn->ntmp);
    for (Blk *b = fn->start; b; b = b->link) {
        bscopy(live, b->out);
        if (rtype(b->jmp.arg) == RTmp)
            bsset(live, b->jmp.arg.val);
        for (Ins *i = b->ins + b->nins; i != b->ins;) {
            --i;
            if (rtype(i->to) == RTmp)
                bsclr(live, i->to.val);
            if (i->op == Ocall || flow_barrier(i)) {
                FlowSite *site = alloc(sizeof *site);
                site->instruction = i;
                bsinit(site->live, fn->ntmp);
                bscopy(site->live, live);
                site->next = sites;
                sites = site;
                Symbol *callee = i->op == Ocall && rtype(i->arg[0]) == RCon ?
                                 call_target(i->arg[0]) : NULL;
                int peak = i->op != Ocall ? 0 : callee ? callee->stack_peak : -1;
                int capacity = peak < 0 ? 0 : 8 - peak;
                for (int t = Tmp0; bsiter(live, &t); ++t) {
                    if (flow_rematerialize(t))
                        continue;
                    if (site->count < capacity)
                        site->saved[site->count++] = t;
                    else
                        flow_spill(t);
                }
            }
            for (int n = 0; n < 2; ++n)
                if (rtype(i->arg[n]) == RTmp)
                    bsset(live, i->arg[n].val);
        }
    }
    return sites;
}

typedef struct {
    int in[FIFO_ARGS * SCHED_STASH], out[FIFO_ARGS * SCHED_STASH];
    int result_in[STASH_A], result_out[STASH_A];
} FlowBlock;

static unsigned char *blocked_result;
static int failed_result;

static int
flow_uses_home(Blk *b, int t)
{
    if (bshas(b->in, t))
        return 1;
    for (Phi *p = b->phi; p; p = p->link)
        if (p->to.val == (unsigned)t && fn->tmp[t].nuse)
            return 1;
    return 0;
}

static unsigned char *forced_spill;
static int failed_temp;

static void
flow_retry_home(const FlowBlock *layout)
{
    for (int unit = 0; unit < STASH_A && !failed_result; ++unit)
        failed_result = layout->result_in[unit] ? layout->result_in[unit] : layout->result_out[unit];
    for (int n = FIFO_ARGS * SCHED_STASH; n-- > 0;) {
        int candidates[] = {layout->in[n], layout->out[n]};
        for (unsigned k = 0; k < sizeof candidates / sizeof *candidates; ++k) {
            int t = candidates[k];
            if (t && (!failed_temp || fn->tmp[t].nuse < fn->tmp[failed_temp].nuse))
                failed_temp = t;
        }
    }
}

static int
flow_home(int *home, int t, int prefer)
{
    if (forced_spill[t]) {
        if (!flow_rematerialize(t))
            flow_spill(t);
        return 1;
    }
    unsigned unavailable = 0;
    int used = 0;
    for (Blk *b = fn->start; b; b = b->link) {
        int in = flow_uses_home(b, t), out_live = bshas(b->out, t);
        if (in || out_live)
            used = 1;
        for (int other = Tmp0; (in || out_live) && other < (int)fn->ntmp; ++other)
            if (home[other] >= 0 && ((in && flow_uses_home(b, other)) ||
                                    (out_live && bshas(b->out, other))))
                unavailable |= 1u << home[other];
    }
    if (!used)
        return 1;
    if (prefer < 0)
        for (Blk *b = fn->start; b; b = b->link)
            for (Phi *p = b->phi; p; p = p->link)
                for (unsigned n = 0; n < p->narg; ++n) {
                    Ref arg = p->arg[n];
                    if (rtype(arg) != RTmp)
                        continue;
                    if (p->to.val == (unsigned)t && home[arg.val] >= 0)
                        prefer = home[arg.val];
                    if (arg.val == (unsigned)t && home[p->to.val] >= 0)
                        prefer = home[p->to.val];
                }
    if (prefer >= 0 && !(unavailable & (1u << prefer))) {
        home[t] = prefer;
        return 1;
    }
    for (int bank = 0; bank < FIFO_ARGS * SCHED_STASH; ++bank)
        if (!(unavailable & (1u << bank))) {
            home[t] = bank;
            return 1;
        }
    if (!flow_rematerialize(t))
        flow_spill(t);
    return 1;
}

static FlowBlock *
flow_homes(void)
{
    filllive(fn);
    FlowBlock *layout = alloc(fn->nblk * sizeof *layout);
    int *home = alloc(fn->ntmp * sizeof *home);
    for (int t = 0; t < fn->ntmp; ++t)
        home[t] = -1;
    for (unsigned n = 0; n < fn->start->nins && ispar(fn->start->ins[n].op); ++n) {
        Ref arg = fn->start->ins[n].to;
        if (!flow_home(home, arg.val, n < FIFO_ARGS ? (int)n : -1))
            return NULL;
    }
    for (Blk *b = fn->start; b; b = b->link)
        for (Phi *p = b->phi; p; p = p->link)
            if (home[p->to.val] < 0 && !flow_home(home, p->to.val, -1))
                return NULL;
    for (int t = Tmp0; t < fn->ntmp; ++t)
        if (home[t] < 0 && !flow_home(home, t, -1))
            return NULL;
    for (Blk *b = fn->start; b; b = b->link)
        for (int t = Tmp0; t < fn->ntmp; ++t) {
            int bank = home[t];
            if (bank < 0)
                continue;
            if (flow_uses_home(b, t))
                layout[b->id].in[bank] = t;
            if (bshas(b->out, t))
                layout[b->id].out[bank] = t;
        }
    return layout;
}

static ResultHome
producer_home(int temp)
{
    Ins *i = fn->tmp[temp].def;
    if (!i || i->cls != Kl)
        return (ResultHome){0};
    switch (i->op) {
    case Oadd: return (ResultHome){ARITH_A, "ADD"};
    case Osub: return (ResultHome){ARITH_A, "SUB"};
    case Omul: return (ResultHome){MUL, "LO"};
    case Oand: return (ResultHome){LOGIC_A, "AND"};
    case Oor: return (ResultHome){LOGIC_A, "OR"};
    case Oxor: return (ResultHome){LOGIC_A, "XOR"};
    case Oneg: return (ResultHome){UOP_A, "NEG"};
    case Oshl: return (ResultHome){SHIFT_A, "LSL"};
    case Oshr: return (ResultHome){SHIFT_A, "LSR"};
    case Osar: return (ResultHome){SHIFT_A, "ASR"};
    default: return (ResultHome){0};
    }
}

static void
clear_home(int *layout, int temp)
{
    for (int n = 0; n < FIFO_ARGS * SCHED_STASH; ++n)
        if (layout[n] == temp)
            layout[n] = 0;
}

/* Limit inter-block carrying to the consuming region, so an ordinary ABI
 * boundary never inherits a compute result with no assigned owner. */
static int
result_consumed_in(int temp, Blk *b)
{
    Tmp *t = &fn->tmp[temp];
    for (unsigned n = 0; n < t->nuse; ++n)
        if (t->use[n].bid == b->id) {
            Use *use = &t->use[n];
            Ins *end = use->type == UJmp ? b->ins + b->nins :
                       use->type == UIns ? use->u.ins : b->ins;
            if (use->type == UPhi || (use->type == UIns && flow_barrier(use->u.ins)))
                return 0;
            for (Ins *i = b->ins; i < end; ++i)
                if (isarg(i->op) || i->op == Ocall || flow_barrier(i))
                    return 0;
            return 1;
        }
    return 0;
}

static void
carry_direct(FlowBlock *layout, Blk *from, int temp, ResultHome home)
{
    Tmp *t = &fn->tmp[temp];
    Blk *targets[] = {from->s1, from->s2};
    int uses[2] = {0};
    for (unsigned n = 0; n < t->nuse; ++n) {
        Use *use = &t->use[n];
        int edge = targets[0] && use->bid == targets[0]->id ? 0 :
                   targets[1] && use->bid == targets[1]->id ? 1 : -1;
        if (edge < 0 || use->type == UPhi || ++uses[edge] > 1)
            return;
    }
    for (int edge = 0; edge < 2; ++edge)
        if (targets[edge] && (targets[edge] == from || targets[edge]->npred != 1 ||
            layout[targets[edge]->id].result_in[home.unit] || !uses[edge] ||
            !result_consumed_in(temp, targets[edge])))
            return;
    layout[from->id].result_out[home.unit] = temp;
    result_home[temp] = home;
    clear_home(layout[from->id].out, temp);
    for (int edge = 0; edge < 2; ++edge)
        if (targets[edge]) {
            FlowBlock *to = &layout[targets[edge]->id];
            to->result_in[home.unit] = temp;
            clear_home(to->in, temp);
        }
}

static void
carry_phi(FlowBlock *layout, Blk *to, Phi *phi)
{
    int temp = phi->to.val;
    if (phi->cls != Kl || phi->narg < 2 || fifo_spill[temp] || blocked_result[temp] ||
        fn->tmp[temp].nuse != 1 || !result_consumed_in(temp, to))
        return;
    ResultHome common = {0};
    for (unsigned n = 0; n < phi->narg; ++n) {
        Ref arg = phi->arg[n];
        Blk *from = phi->blk[n];
        if (rtype(arg) != RTmp || blocked_result[arg.val] || fifo_spill[arg.val] ||
            from == to || from->jmp.type != Jjmp)
            return;
        Tmp *t = &fn->tmp[arg.val];
        if (t->bid != from->id || t->nuse != 1)
            return;
        ResultHome home = producer_home(arg.val);
        if (!home.port || layout[from->id].result_out[home.unit] ||
            (common.port && (home.unit != common.unit || strcmp(home.port, common.port))))
            return;
        common = home;
    }
    if (layout[to->id].result_in[common.unit])
        return;
    layout[to->id].result_in[common.unit] = temp;
    result_home[temp] = common;
    clear_home(layout[to->id].in, temp);
    for (unsigned n = 0; n < phi->narg; ++n) {
        int arg = phi->arg[n].val;
        FlowBlock *from = &layout[phi->blk[n]->id];
        from->result_out[common.unit] = arg;
        result_home[arg] = common;
        clear_home(from->out, arg);
    }
}

static void
flow_result_homes(FlowBlock *layout)
{
    result_home = alloc(fn->ntmp * sizeof *result_home);
    for (Blk *b = fn->start; b; b = b->link) {
        for (Phi *phi = b->phi; phi; phi = phi->link)
            carry_phi(layout, b, phi);
        if (!b->s1)
            continue;
        for (int t = Tmp0; bsiter(b->out, &t); ++t) {
            if (fn->tmp[t].bid != b->id || blocked_result[t] || fifo_spill[t] || result_home[t].port)
                continue;
            ResultHome home = producer_home(t);
            if (home.port && !layout[b->id].result_out[home.unit])
                carry_direct(layout, b, t, home);
        }
    }
}

static void
flow_seed_results(const FlowBlock *layout)
{
    for (int unit = 0; unit < STASH_A; ++unit) {
        int temp = layout->result_in[unit];
        if (!temp)
            continue;
        SchedValue seed = sched_node(unit, result_home[temp].port, 0, NULL);
        if (seed.node)
            scheduled.node[seed.node - 1].pinned = 1;
        scheduled_value[temp] = seed;
        scheduled_known[temp] = 1;
    }
}

static void
flow_seed(int bank, int temp)
{
    scheduled_value[temp] = sched_node(STASH_A + bank, "OUT", 0, NULL);
    scheduled_known[temp] = 1;
}

static SchedValue
flow_word(Ref ref)
{
    if (rtype(ref) == RTmp && fn->tmp[ref.val].cls == Kw && !uncanonical_word[ref.val])
        return sched_value(ref);
    if (rtype(ref) == RCon && fn->con[ref.val].type != CAddr) {
        if (fn->con[ref.val].flt)
            error("floating-point operand");
        return sched_number((uint32_t)fn->con[ref.val].bits.i);
    }
    return sched_extend(sched_value(ref), 32, 0);
}

static void
flow_begin(const int *input)
{
    scheduled.fifo_flow = 1;
    scheduled.count = schedule_overflow = 0;
    scheduled.term = (SchedTerm){0};
    scheduled_sp = (SchedValue){0};
    memset(scheduled.live_out, 0, sizeof scheduled.live_out);
    memset(scheduled.result_out, 0, sizeof scheduled.result_out);
    memset(scheduled.saved, 0, sizeof scheduled.saved);
    memset(scheduled_known, 0, fn->ntmp * sizeof *scheduled_known);
    memset(uncanonical_word, 0, fn->ntmp * sizeof *uncanonical_word);
    for (int n = 0; n < FIFO_ARGS * SCHED_STASH; ++n)
        if (input[n])
            flow_seed(n % FIFO_ARGS, input[n]);
}

static int
flow_finish(const int *wanted, SchedValue *result)
{
    if (schedule_overflow)
        return 0;
    unsigned char used[SCHED_NODES + 1] = {0}, kept[SCHED_NODES + 1] = {0};
    int count[FIFO_ARGS] = {0};
    for (int i = 0; i < scheduled.count; ++i)
        for (int j = 0; j < scheduled.node[i].count; ++j)
            used[scheduled.node[i].move[j].value.node] = 1;
    for (int n = 0; n < FIFO_ARGS * SCHED_STASH; ++n)
        if (wanted[n])
            used[result[n].node] = 1;
    for (int unit = 0; unit < STASH_A; ++unit)
        used[scheduled.result_out[unit]] = 1;
    for (int n = 0; n < 8 && scheduled.saved[n]; ++n)
        used[scheduled.saved[n]] = 1;
    int condition = 0;
    for (int i = 0; i < scheduled.count; ++i)
        if (scheduled.node[i].unit == CONTROL && !strcmp(scheduled.node[i].move[0].sink, "COND"))
            condition = i + 1;
    int nodes = scheduled.count;
    for (int i = 1; i <= nodes; ++i)
        if (scheduled.node[i - 1].result && !used[i])
            sched_node(CONTROL, NULL, 1, (SchedMove[]){{"DISCARD", {.node = i}}});
    for (int n = 0; n < FIFO_ARGS * SCHED_STASH; ++n) {
        if (!wanted[n])
            continue;
        int bank = n % FIFO_ARGS;
        enum SchedUnit unit = STASH_A + bank;
        SchedValue source = result[n];
        if (source.node && scheduled.node[source.node - 1].unit == unit) {
            if (kept[source.node])
                source = sched_node(HOLD, "OUT", 1, (SchedMove[]){{NULL, source}});
            else {
                kept[source.node] = 1;
                scheduled.live_out[bank][count[bank]++] = source.node;
                continue;
            }
        }
        if (condition && source.node &&
            scheduled.node[condition - 1].move[0].value.node == source.node) {
            SchedNode *node = &scheduled.node[condition - 1];
            node->unit = unit;
            node->result = "OUT";
            node->count = 2;
            node->move[0].sink = "CPU.COND";
            node->move[1] = (SchedMove){"IN", source};
            source = (SchedValue){.node = condition};
            condition = 0;
        } else {
            source = sched_node(unit, "OUT", 1, (SchedMove[]){{"IN", source}});
        }
        scheduled.live_out[bank][count[bank]++] = source.node;
    }
    return !schedule_overflow && schedule_emit(out, &scheduled, 0, -1);
}

static SchedValue
flow_param(Ins *param, unsigned n)
{
    if (n < FIFO_ARGS)
        return scheduled_value[param->to.val];
    char *label = alloc(32);
    arg_label(label, n);
    SchedValue value = sched_read((SchedValue){.imm = label});
    return param->cls == Kw ? sched_extend(value, 32, 0) : value;
}

static SchedValue
flow_arg(Ins *arg)
{
    if (isargbh(arg->op)) {
        unsigned n = arg->op - Oargsb;
        SchedValue v = sched_extend(sched_value(arg->arg[0]), n < 2 ? 8 : 16, !(n & 1));
        return sched_extend(v, 32, 0);
    }
    return arg->cls == Kw ? flow_word(arg->arg[0]) : sched_value(arg->arg[0]);
}

static void
flow_save(FlowSite *site)
{
    for (int t = Tmp0; bsiter(site->live, &t); ++t) {
        if (flow_rematerialize(t))
            continue;
        int n = 0;
        while (n < site->count && site->saved[n] != t)
            ++n;
        if (n < site->count) {
            SchedValue v = sched_value(TMP(t));
            scheduled.saved[n] = sched_node(STACK_A, "TOP", 1, (SchedMove[]){{"PUSH", v}}).node;
        } else if (scheduled_known[t])
            sched_write(sched_address(fifo_spill[t] - 1), scheduled_value[t], (SchedValue){0});
    }
}

static void
flow_resume(const FlowSite *site, Ref to)
{
    int input[FIFO_ARGS * SCHED_STASH] = {0};
    if (!req(to, R))
        input[0] = to.val;
    int next = 0;
    for (int n = site->count; n-- > 0;) {
        while (input[next])
            ++next;
        move("STACK_A.TOP", abi_stash[next % FIFO_ARGS]);
        input[next++] = site->saved[n];
    }
    flow_begin(input);
}

static FlowSite *
flow_site(FlowSite *sites, const Ins *i)
{
    for (; sites; sites = sites->next)
        if (sites->instruction == i)
            return sites;
    return NULL;
}

static int
flow_call(Ins *args, Ins *call, FlowSite *site)
{
    int abi[FIFO_ARGS * SCHED_STASH] = {0};
    SchedValue result[FIFO_ARGS * SCHED_STASH] = {{0}};
    if (rtype(call->arg[1]) == RType || call->cls > Kl)
        error("unsupported call result type");
    int indirect = rtype(call->arg[0]) != RCon;
    if (indirect) {
        abi[0] = 1;
        result[0] = sched_value(call->arg[0]);
    }
    for (Ins *arg = args; arg < call; ++arg) {
        if ((arg->op != Oarg && !isargbh(arg->op)) || arg->cls > Kl)
            error("unsupported call argument");
        unsigned n = arg - args;
        SchedValue v = flow_arg(arg);
        if (n < FIFO_ARGS) {
            int index = !n && indirect ? FIFO_ARGS : (int)n;
            abi[index] = 1;
            result[index] = v;
        } else {
            char *label = alloc(32);
            arg_label(label, n);
            sched_write((SchedValue){.imm = label}, v, (SchedValue){0});
        }
    }
    int park = current_function->depth < 0;
    const char *target = indirect ? NULL : call_target(call->arg[0])->label;
    if (!park && !indirect)
        scheduled.term = (SchedTerm){TERM_CALL, target};
    flow_save(site);
    if (!flow_finish(abi, result))
        return 0;


    if (park) {
        address(0, "MEM.WRITE");
        line("STACK_B.TOP -> MEM.CHUNK, ZERO -> MEM.MASK [sync]");
    }
    if (indirect)
        line("PC_NEXT -> STACK_B.PUSH, " A " -> PC [sync]");
    else if (park)
        line("PC_NEXT -> STACK_B.PUSH, CONST -> PC_REL [sync, rel=%s]", target);
    if (park)
        load_frame(0, "STACK_B.PUSH");
    if (req(call->to, R))
        move(A, "DISCARD");
    flow_resume(site, call->to);
    return 1;
}

static void
flow_blit(unsigned bytes)
{
    for (unsigned n = 0; n < bytes; ++n) {
        line(A " -> " A ", " A " -> ARITH_A.LHS, CONST -> ARITH_A.RHS [sync, imm=%u]", n);
        typed_load("ARITH_A.ADD", 0, D);
        line(B " -> " B ", " B " -> ARITH_B.LHS, CONST -> ARITH_B.RHS [sync, imm=%u]", n);
        typed_store("ARITH_B.ADD", D, 0);
    }
    move(A, "DISCARD");
    move(B, "DISCARD");
}

static int
flow_inline(Ins *i, FlowSite *site)
{
    int abi[FIFO_ARGS * SCHED_STASH] = {1, 1};
    SchedValue args[FIFO_ARGS * SCHED_STASH] = {{0}};
    args[0] = sched_value(i->arg[0]);
    args[1] = sched_value(i->arg[1]);
    flow_save(site);
    if (!flow_finish(abi, args))
        return 0;
    if (i->op == Oblit0) {
        flow_blit(rsval(i[1].arg[0]));
    } else {
        int sign = i->op == Odiv || i->op == Orem;
        const char *unit = sign ? "DIVS" : "DIV";
        if (i->cls == Kw) {
            extend(A, A, 32, sign);
            extend(B, B, 32, sign);
        }
        line(A " -> %s.LHS, " B " -> %s.RHS [sync]", unit, unit);
        line("%s.%s -> " D, unit, i->op == Orem || i->op == Ourem ? "REM" : "QUO");
    }
    if (!req(i->to, R)) {
        if (i->cls == Kw)
            extend(D, A, 32, 0);
        else
            move(D, A);
    }
    flow_resume(site, i->to);
    return 1;
}

static int
low_word_use(const Ins *i)
{
    if (i->cls != Kw)
        return 0;
    switch (i->op) {
    case Oadd: case Osub: case Omul: case Oneg:
    case Oand: case Oor: case Oxor: case Oshl: case Ocopy:
        return 1;
    default:
        return 0;
    }
}

static int
defer_word(Ins *producer, const Ins *region_end)
{
    if (!low_word_use(producer))
        return 0;
    Tmp *tmp = &fn->tmp[producer->to.val];
    for (unsigned n = 0; n < tmp->nuse; ++n) {
        Use *use = &tmp->use[n];
        if (use->bid != block->id || use->type == UPhi)
            return 0;
        if (use->type == UJmp) {
            if (region_end != block->ins + block->nins || block->jmp.type == Jretl)
                return 0;
        } else if (use->type != UIns || use->u.ins >= region_end || !low_word_use(use->u.ins))
            return 0;
    }
    return 1;
}

/* The predicate FIFO tests the whole value for nonzero. The compared value
 * must stay in the final scheduling region, where its use can move to the jump. */
static Ins *
flow_nonzero_test(BranchFact *fact)
{
    *fact = branch_fact(block, 1);
    if (!fact->bits || fact->cmp != Cine || fact->constant)
        return NULL;
    Tmp *condition = &fn->tmp[block->jmp.arg.val];
    if (condition->nuse != 1)
        return NULL;
    Ins *test = condition->def;
    for (Ins *i = test + 1; i < block->ins + block->nins; ++i)
        if (isarg(i->op) || i->op == Ocall || flow_barrier(i))
            return NULL;
    return test;
}

static int
flow_block(FlowBlock *layout, FlowSite *sites, SchedTerm term)
{
    flow_begin(layout->in);
    flow_seed_results(layout);
    BranchFact truth;
    Ins *nonzero = flow_nonzero_test(&truth);
    unsigned params = 0;
    if (block == fn->start) {
        while (params < block->nins && ispar(block->ins[params].op)) {
            if (params < FIFO_ARGS)
                flow_seed(params, block->ins[params].to.val);
            ++params;
        }
        for (unsigned n = FIFO_ARGS; n < params; ++n) {
            Ref dst = block->ins[n].to;
            scheduled_value[dst.val] = flow_param(&block->ins[n], n);
            scheduled_known[dst.val] = 1;
        }
    }
    Ins *region_start = block->ins + params, *region_end = region_start;
    for (Ins *i = block->ins + params; i < block->ins + block->nins && !schedule_overflow; ++i) {
        if (i == nonzero || i->op == Onop || i->op == Odbgloc)
            continue;
        if (isarg(i->op) || i->op == Ocall) {
            Ins *args = i;
            while (i < block->ins + block->nins && isarg(i->op))
                ++i;
            if (i == block->ins + block->nins || i->op != Ocall)
                error("argument without a call");
            FlowSite *site = flow_site(sites, i);
            if (!site || !flow_call(args, i, site))
                return 0;
            continue;
        }
        if (flow_barrier(i)) {
            FlowSite *site = flow_site(sites, i);
            if (!site || !flow_inline(i, site))
                return 0;
            if (i->op == Oblit0)
                ++i;
            continue;
        }
        if (region_end <= i) {
            region_start = i;
            region_end = i + 1;
            while (region_end < block->ins + block->nins && !isarg(region_end->op) &&
                   region_end->op != Ocall && !flow_barrier(region_end))
                ++region_end;
        }
        if (folded_shift(i, region_start, region_end))
            continue;
        SchedValue result = isalloc(i->op) ? sched_address(objects[i->to.val]) :
                                           sched_instruction(i, region_start);
        if (req(i->to, R))
            continue;
        if (i->cls == Kw && !INRANGE(i->op, Ocmpw, Ocmpl1)) {
            if (defer_word(i, region_end))
                uncanonical_word[i->to.val] = 1;
            else
                result = sched_extend(result, 32, 0);
        }
        if (result.node && result_home[i->to.val].port)
            scheduled.node[result.node - 1].pinned = 1;
        scheduled_value[i->to.val] = result;
        scheduled_known[i->to.val] = 1;
    }
    for (int t = Tmp0; bsiter(block->out, &t); ++t) {
        int resident = 0;
        for (int n = 0; n < FIFO_ARGS * SCHED_STASH; ++n)
            resident |= layout->out[n] == t;
        if (!resident && fifo_spill[t] && scheduled_known[t])
            sched_write(sched_address(fifo_spill[t] - 1), scheduled_value[t], (SchedValue){0});
    }
    int jump = block->jmp.type;
    int returning = isret(jump) || isretbh(jump);
    SchedValue result[FIFO_ARGS * SCHED_STASH] = {{0}};
    if (jump == Jjnz) {
        SchedValue condition;
        if (nonzero)
            condition = truth.bits == 32 ? flow_word(truth.value) : sched_value(truth.value);
        else
            condition = flow_word(block->jmp.arg);
        sched_node(CONTROL, NULL, 1, (SchedMove[]){{"COND", condition}});
    }
    if (returning && jump != Jret0) {
        Ref arg = block->jmp.arg;
        result[0] = jump == Jretl ? sched_value(arg) : flow_word(arg);
        if (isretbh(jump)) {
            unsigned n = jump - Jretsb;
            result[0] = sched_extend(result[0], n < 2 ? 8 : 16, !(n & 1));
            result[0] = sched_extend(result[0], 32, 0);
        }
    }
    for (int n = 0; n < FIFO_ARGS * SCHED_STASH; ++n)
        if (layout->out[n])
            result[n] = sched_value(TMP(layout->out[n]));
    for (int unit = 0; unit < STASH_A; ++unit)
        if (layout->result_out[unit])
            scheduled.result_out[unit] = sched_value(TMP(layout->result_out[unit])).node;
    scheduled.term = term;
    if (returning) {
        int abi[FIFO_ARGS * SCHED_STASH] = {1};
        return flow_finish(abi, result);
    }
    return flow_finish(layout->out, result);
}

static Ref
flow_phi_arg(Blk *from, Phi *phi)
{
    Ref arg = incoming_value(phi, from);
    if (req(arg, R))
        error("missing phi input");
    return arg;
}

static int
flow_edge(Blk *from, Blk *to, const FlowBlock *layout, SchedTerm term)
{
    const FlowBlock *source = &layout[from->id], *target = &layout[to->id];
    flow_begin(source->out);
    for (int unit = 0; unit < STASH_A; ++unit) {
        int incoming = target->result_in[unit], produced = source->result_out[unit];
        if (!incoming && !produced)
            continue;
        if (!incoming || !produced)
            return 0;
        Ref arg = TMP(incoming);
        for (Phi *phi = to->phi; phi; phi = phi->link)
            if (req(phi->to, arg)) {
                arg = flow_phi_arg(from, phi);
                break;
            }
        if (!req(arg, TMP(produced)))
            return 0;
        SchedValue seed = sched_node(unit, result_home[produced].port, 0, NULL);
        if (!seed.node)
            return 0;
        scheduled.node[seed.node - 1].pinned = 1;
        scheduled_value[produced] = seed;
        scheduled_known[produced] = 1;
        scheduled.result_out[unit] = seed.node;
    }
    SchedValue result[FIFO_ARGS * SCHED_STASH] = {{0}};
    for (int n = 0; n < FIFO_ARGS * SCHED_STASH; ++n) {
        int temp = layout[to->id].in[n];
        if (!temp)
            continue;
        Ref arg = TMP(temp);
        for (Phi *p = to->phi; p; p = p->link)
            if (req(p->to, arg)) {
                arg = flow_phi_arg(from, p);
                break;
            }
        result[n] = fn->tmp[temp].cls == Kw ? flow_word(arg) : sched_value(arg);
    }
    SchedValue *incoming = alloc(fn->ntmp * sizeof *incoming);
    for (Phi *p = to->phi; p; p = p->link) {
        if (!fifo_spill[p->to.val] || !fn->tmp[p->to.val].nuse)
            continue;
        int resident = 0;
        for (int n = 0; n < FIFO_ARGS * SCHED_STASH; ++n)
            resident |= layout[to->id].in[n] == (int)p->to.val;
        if (resident)
            continue;
        Ref arg = flow_phi_arg(from, p);
        incoming[p->to.val] = p->cls == Kw ? flow_word(arg) : sched_value(arg);
    }
    for (Phi *p = to->phi; p; p = p->link) {
        if (!fifo_spill[p->to.val] || !fn->tmp[p->to.val].nuse)
            continue;
        int resident = 0;
        for (int n = 0; n < FIFO_ARGS * SCHED_STASH; ++n)
            resident |= layout[to->id].in[n] == (int)p->to.val;
        if (!resident)
            sched_write(sched_address(fifo_spill[p->to.val] - 1), incoming[p->to.val], (SchedValue){0});
    }
    scheduled.term = term;
    return flow_finish(layout[to->id].in, result);
}

typedef struct {
    char *code;
    enum { EDGE_EMPTY, EDGE_INLINE, EDGE_ENTRY, EDGE_PRED, EDGE_OUTLINE } placement;
    SchedTerm term;
} FlowEdge;

static const char *
flow_label(const Symbol *f, const Blk *from, const Blk *to)
{
    char *label = alloc(strlen(f->label) + 32);
    if (from)
        sprintf(label, "%s_e%u_%u", f->label, from->id, to->id);
    else
        sprintf(label, "%s_b%u", f->label, to->id);
    return label;
}

static void
flow_order(void)
{
    Blk **original = alloc(fn->nblk * sizeof *original);
    unsigned char *placed = alloc(fn->nblk);
    unsigned count = 0, next = 0;
    for (Blk *b = fn->start; b; b = b->link)
        original[count++] = b;
    Blk *b = fn->start;
    for (;;) {
        placed[b->id] = 1;
        Blk *fallthrough = b->jmp.type == Jjmp ? b->s1 : b->jmp.type == Jjnz ? b->s2 : NULL;
        if (!fallthrough || placed[fallthrough->id]) {
            while (next < count && placed[original[next]->id])
                ++next;
            fallthrough = next < count ? original[next++] : NULL;
        }
        b->link = fallthrough;
        if (!fallthrough)
            break;
        b = fallthrough;
    }
}

static int
flow_exit_is_return(Blk *b, const FlowBlock *layout)
{
    Ref result = b->jmp.arg;
    if (frame_size || (b->jmp.type != Jretw && b->jmp.type != Jretl) ||
        rtype(result) != RTmp || (b->jmp.type == Jretw && fn->tmp[result.val].cls != Kw) ||
        layout[b->id].in[0] != (int)result.val)
        return 0;
    for (int i = 1; i < FIFO_ARGS * SCHED_STASH; ++i)
        if (layout[b->id].in[i])
            return 0;
    for (int unit = 0; unit < STASH_A; ++unit)
        if (layout[b->id].result_in[unit])
            return 0;
    for (Ins *i = b->ins; i < b->ins + b->nins; ++i)
        if (i->op != Onop && i->op != Odbgloc)
            return 0;
    return 1;
}

static int
flow_buffer_edge(FlowEdge *edge, Blk *from, Blk *to, const FlowBlock *layout, SchedTerm term)
{
    size_t size = 0;
    char *code = NULL;
    FILE *saved = out;
    out = open_memstream(&code, &size);
    if (!out)
        error("cannot buffer FIFO edge");
    int ok = flow_edge(from, to, layout, term);
    if (fclose(out))
        error("cannot buffer FIFO edge");
    out = saved;
    if (ok) {
        free(edge->code);
        edge->code = code;
    } else
        free(code);
    return ok;
}

static int
flow_plan_edge(const Symbol *f, FlowEdge *edge, Blk *from, Blk *to,
               const FlowBlock *layout, char **entries, int taken)
{
    if (!flow_buffer_edge(edge, from, to, layout, (SchedTerm){0}))
        return 0;
    const char *target = flow_label(f, NULL, to);
    if (taken) {
        if (!*edge->code)
            return 1;
        if (flow_buffer_edge(edge, from, to, layout, (SchedTerm){TERM_PRED, target})) {
            edge->placement = EDGE_PRED;
            return 1;
        }
        if (to->npred == 1 && to != fn->start) {
            edge->placement = EDGE_ENTRY;
            entries[to->id] = edge->code;
            return 1;
        }
        edge->placement = EDGE_OUTLINE;
        return flow_buffer_edge(edge, from, to, layout, (SchedTerm){TERM_JUMP, target});
    }

    edge->term = flow_exit_is_return(to, layout) ? (SchedTerm){TERM_RETURN, NULL} :
                 to != from->link ? (SchedTerm){TERM_JUMP, target} : (SchedTerm){0};
    if (*edge->code) {
        edge->placement = EDGE_INLINE;
        if (edge->term.kind)
            return flow_buffer_edge(edge, from, to, layout, edge->term);
    }
    return 1;
}

static int
flow_function(Symbol *f)
{
    frame_size = f->depth < 0 ? 8 : 0;
    objects = alloc(fn->ntmp * sizeof *objects);
    fifo_spill = alloc(fn->ntmp * sizeof *fifo_spill);
    for (Blk *b = fn->start; b; b = b->link)
        for (Ins *i = b->ins; i < b->ins + b->nins; ++i) {
            if (isalloc(i->op)) {
                if (b != fn->start || rtype(i->arg[0]) != RCon)
                    error("only constant entry-block allocations are supported");
                Con *size = &fn->con[i->arg[0].val];
                if (size->type != CBits || size->flt || size->bits.i < 0)
                    error("invalid allocation size");
                frame_size = align_up(frame_size, 4u << (i->op - Oalloc4));
                if ((uint64_t)size->bits.i > SIZE_MAX - frame_size)
                    error("frame size overflow");
                objects[i->to.val] = frame_size;
                frame_size += size->bits.i;
            } else if (ispar(i->op)) {
                if (i->cls > Kl || (i->op != Opar && !isparbh(i->op)))
                    return 0;
            } else if (i->op >= Ostores && i->op <= Ostored) {
                return 0;
            } else if (!isarg(i->op) && i->op != Ocall && i->op != Oblit1 &&
                       !sched_eligible(i) && !(i->cls <= Kl && flow_barrier(i)))
                return 0;
        }

    FlowBlock *layout = flow_homes();
    if (!layout)
        return 0;
    flow_result_homes(layout);
    FlowSite *sites = flow_sites();
    frame_size = align_up(frame_size, 16);
    if (frame_size > INT64_MAX)
        error("frame size overflow");
    flow_order();
    FlowEdge *edges = alloc(2 * fn->nblk * sizeof *edges);
    char **entries = alloc(fn->nblk * sizeof *entries);
    int ok = 1;
    fifo_only = 1;
    for (Blk *b = fn->start; ok && b; b = b->link) {
        Blk *targets[] = {b->s1, b->s2};
        for (int n = 0; ok && n < 2; ++n) {
            if (!targets[n])
                continue;
            ok = flow_plan_edge(f, &edges[2 * b->id + n], b, targets[n], layout,
                                entries, b->jmp.type == Jjnz && n == 0);
            if (!ok) {
                flow_retry_home(&layout[b->id]);
                flow_retry_home(&layout[targets[n]->id]);
            }
        }
    }
    unsigned char *referenced = alloc(fn->nblk);
    referenced[fn->start->id] = 1;
    for (Blk *b = fn->start; b; b = b->link) {
        FlowEdge *edge = &edges[2 * b->id];
        if (b->s1 && edge[0].term.kind != TERM_RETURN)
            referenced[b->s1->id] = 1;
        if (b->s2 && edge[1].term.kind != TERM_RETURN)
            referenced[b->s2->id] = 1;
    }
    if (ok) {
        line("%s:", f->label);
        if (frame_size) {
            load_global(SP, "ARITH_B.LHS");
            number(frame_size, "ARITH_B.RHS");
            store_global(SP, "ARITH_B.ADD");
        }
    }
    for (block = fn->start; ok && block; block = block->link) {
        if (!referenced[block->id] && flow_exit_is_return(block, layout))
            continue;
        FlowBlock *here = &layout[block->id];
        FlowEdge *edge = &edges[2 * block->id];
        line("%s_b%u:", f->label, block->id);
        if (entries[block->id])
            fputs(entries[block->id], out);
        int op = block->jmp.type;
        int returning = isret(op) || isretbh(op);
        SchedTerm term = {0};
        if (returning && !frame_size)
            term.kind = TERM_RETURN;
        else if (op == Jjmp && edge[0].placement == EDGE_EMPTY)
            term = edge[0].term;
        ok = flow_block(here, sites, term);
        if (!ok) {
            flow_retry_home(here);
            break;
        }
        if (returning) {
            if (frame_size) {
                address(0, "STASH_D");
                store_global(SP, D);
                move("STACK_B.TOP", "PC");
            }
        } else if (op == Jhlt)
            literal("3", "PC");
        else if (op == Jjmp) {
            if (edge[0].placement == EDGE_INLINE)
                fputs(edge[0].code, out);
        } else if (op == Jjnz) {
            if (edge[0].placement == EDGE_PRED)
                fputs(edge[0].code, out);
            else
                line("CONST -> PC_REL [pred, rel=%s]", flow_label(f,
                     edge[0].placement == EDGE_OUTLINE ? block : NULL, block->s1));
            if (edge[1].placement == EDGE_INLINE)
                fputs(edge[1].code, out);
            else if (edge[1].term.kind == TERM_RETURN)
                move("STACK_B.TOP", "PC");
            else if (edge[1].term.kind == TERM_JUMP)
                line("CONST -> PC_REL [rel=%s]", edge[1].term.target);
        } else
            ok = 0;
    }
    fifo_only = 0;
    for (Blk *b = fn->start; b; b = b->link) {
        FlowEdge *edge = &edges[2 * b->id];
        if (ok && edge[0].placement == EDGE_OUTLINE) {
            line("%s:", flow_label(f, b, b->s1));
            fputs(edge[0].code, out);
        }
        free(edge[0].code);
        free(edge[1].code);
    }
    return ok;
}

static int
split_long_blocks(void)
{
    int split = 0;
    for (Blk *b = fn->start; b; b = b->link) {
        if (b->nins <= SCHED_REGION)
            continue;
        unsigned n = SCHED_REGION;
        while (n < b->nins && (ispar(b->ins[n].op) || isarg(b->ins[n].op) ||
                               b->ins[n].op == Ocall || b->ins[n].op == Oblit1))
            ++n;
        if (n == b->nins)
            continue;
        Blk *tail = newblk();
        tail->ins = b->ins + n;
        tail->nins = b->nins - n;
        tail->jmp = b->jmp;
        tail->s1 = b->s1;
        tail->s2 = b->s2;
        tail->link = b->link;
        tail->name = b->name;
        Blk *successors[] = {b->s1, b->s2};
        for (unsigned s = 0; s < 2; ++s)
            if (successors[s])
                for (Phi *p = successors[s]->phi; p; p = p->link)
                    for (unsigned k = 0; k < p->narg; ++k)
                        if (p->blk[k] == b)
                            p->blk[k] = tail;
        b->nins = n;
        b->jmp.type = Jjmp;
        b->jmp.arg = R;
        b->link = b->s1 = tail;
        b->s2 = NULL;
        split = 1;
    }
    if (split) {
        fillcfg(fn);
        filluse(fn);
    }
    return split;
}

static int
try_fifo_function(Symbol *f, int split)
{
    forced_spill = alloc(fn->ntmp * sizeof *forced_spill);
    blocked_result = alloc(fn->ntmp * sizeof *blocked_result);
    unsigned label_base = serial;
    FILE *saved = out;
    /* Limit retries when the FIFO order would require an expensive shuffle. */
    for (int attempt = 0; attempt < 5; ++attempt) {
        char *assembly = NULL;
        size_t size = 0;
        failed_temp = failed_result = 0;
        out = open_memstream(&assembly, &size);
        if (!out)
            error("cannot buffer FIFO function");
        int ok = flow_function(f);
        if (fclose(out))
            error("cannot buffer FIFO function");
        out = saved;
        block = NULL;
        if (ok)
            fwrite(assembly, 1, size, out);
        free(assembly);
        if (ok)
            return 1;
        serial = label_base;
        schedule_reset_peak();
        if (split && !attempt && schedule_overflow && split_long_blocks())
            continue;
        if (failed_result)
            blocked_result[failed_result] = 1;
        else if (failed_temp)
            forced_spill[failed_temp] = 1;
        else
            break;
    }
    return 0;
}

static unsigned
new_aligned_accesses(const unsigned char *baseline)
{
    unsigned count = 0;
    for (Blk *b = fn->start; b; b = b->link) {
        if (b->loop <= 1)
            continue;
        for (Ins *i = b->ins; i < b->ins + b->nins; ++i) {
            int store = isstore(i->op);
            if (!store && !isload(i->op))
                continue;
            Ref addr = i->arg[store];
            if (rtype(addr) == RTmp && baseline[addr.val] < memory_width(i) &&
                tmp_alignment[addr.val] >= memory_width(i))
                ++count;
        }
    }
    return count;
}

static int
try_aligned_function(Symbol *f)
{
    if (!f->nparam || f->nparam > FIFO_ARGS || f->calls || f->indirect || f->depth < 0)
        return 0;
    unsigned char assumed[FIFO_ARGS] = {0};
    for (unsigned n = 0; n < f->nparam; ++n) {
        const Ins *i = &fn->start->ins[n];
        if (i->op == Opar && i->cls == Kl)
            assumed[n] = 8;
    }
    fillloop(fn);
    unsigned char *baseline = alloc(fn->ntmp);
    memcpy(baseline, tmp_alignment, fn->ntmp);
    compute_alignment(f, assumed);
    unsigned count = new_aligned_accesses(baseline);
    if (count < 2) {
        memcpy(tmp_alignment, baseline, fn->ntmp);
        return 0;
    }
    for (unsigned n = 0; n < f->nparam; ++n) {
        unsigned align = baseline[fn->start->ins[n].to.val];
        while (assumed[n] > align) {
            assumed[n] /= 2;
            compute_alignment(f, assumed);
            if (new_aligned_accesses(baseline) != count) {
                assumed[n] *= 2;
                break;
            }
        }
    }

    /* Both versions must schedule before publishing the entry guard. */
    Blk **order = alloc(fn->nblk * sizeof *order);
    unsigned nblocks = 0;
    for (Blk *b = fn->start; b; b = b->link)
        order[nblocks++] = b;
    unsigned label_base = serial;
    FILE *saved = out;
    char *body = NULL;
    size_t size = 0;
    out = open_memstream(&body, &size);
    if (!out)
        error("cannot buffer aligned function");
    char *label = alloc(strlen(f->label) + sizeof "_generic");
    sprintf(label, "%s_aligned", f->label);
    Symbol version = *f;
    version.label = label;
    compute_alignment(f, assumed);
    int ok = try_fifo_function(&version, 0);
    int peak = schedule_stack_peak();
    for (unsigned n = 0; n < nblocks; ++n)
        order[n]->link = n + 1 < nblocks ? order[n + 1] : NULL;
    sprintf(label, "%s_generic", f->label);
    memcpy(tmp_alignment, baseline, fn->ntmp);
    schedule_reset_peak();
    ok = ok && try_fifo_function(&version, 0);
    if (fclose(out))
        error("cannot buffer aligned function");
    out = saved;
    if (ok) {
        line("%s:", f->label);
        for (unsigned n = 0; n < f->nparam; ++n) {
            if (assumed[n] <= baseline[fn->start->ins[n].to.val])
                continue;
            line("%s.OUT -> %s.IN, %s.OUT -> LOGIC_A.LHS, CONST -> LOGIC_A.RHS [sync, imm=%u]",
                 abi_stash[n], abi_stash[n], abi_stash[n], assumed[n] - 1);
            move("LOGIC_A.AND", "COND");
            line("CONST -> PC_REL [pred, rel=%s]", label);
        }
        fwrite(body, 1, size, out);
        if (analyze_leaves)
            current_function->stack_peak = peak > schedule_stack_peak() ? peak : schedule_stack_peak();
    } else {
        for (unsigned n = 0; n < nblocks; ++n)
            order[n]->link = n + 1 < nblocks ? order[n + 1] : NULL;
        serial = label_base;
        schedule_reset_peak();
    }
    free(body);
    return ok;
}

static size_t
align_up(size_t n, size_t alignment)
{
    if (n > SIZE_MAX - alignment + 1)
        error("frame size overflow");
    return (n + alignment - 1) & ~(alignment - 1);
}

static void
function(Fn *parsed)
{
    fn = parsed;
    tmp_alignment = NULL;
    unsigned argc = 0;
    if (collect) {
        Symbol *f = define(fn->name, &fn->lnk, 1);
        unsigned params = 0;
        for (Blk *b = fn->start; b; b = b->link)
            for (Ins *i = b->ins; i < b->ins + b->nins; ++i)
                if (ispar(i->op))
                    ++params;
                else if (isarg(i->op))
                    ++argc;
                else if (i->op == Ocall) {
                    if (argc > max_args)
                        max_args = argc;
                    argc = 0;
                    if (rtype(i->arg[0]) == RCon) {
                        Con *c = &fn->con[i->arg[0].val];
                        if (c->type == CAddr && !c->bits.i && !(c->sym.type & SThr)) {
                            CallEdge *edge = emalloc(sizeof *edge);
                            edge->name = strdup(str(c->sym.id));
                            if (!edge->name)
                                error("cannot save call target");
                            edge->next = f->calls;
                            f->calls = edge;
                            continue;
                        }
                    }
                    f->indirect = 1;
                }
        if (params > max_args)
            max_args = params;
        f->nparam = params;
        if (optimize && params) {
            f->param_align = emalloc(params);
            memset(f->param_align, 8, params);
        }
        goto done;
    }
    if (fn->vararg || fn->retty >= 0)
        error("unsupported function signature");
    Symbol *f = lookup(fn->name, fn->lnk.export ? 0 : module);
    if (collect_inline) {
        find_address_taken();
        collect_inline_body(f);
        goto done;
    }
    if (analyze_alignment) {
        infer_parameter_alignment(f);
        goto done;
    }
    current_function = f;
    if (analyze_leaves && (f->calls || f->indirect))
        goto done;
    schedule_reset_peak();
    int main_entry = f->module == 0 && strcmp(f->name, "main") == 0;
    if (optimize) {
        promote_locals();
        inline_calls();
        if (!main_entry && countdown_function(f))
            goto emitted;
        fold_known_branches();
        rotate_loops();
        compute_alignment(f, NULL);
        scheduled_value = alloc(fn->ntmp * sizeof *scheduled_value);
        scheduled_known = alloc(fn->ntmp * sizeof *scheduled_known);
        uncanonical_word = alloc(fn->ntmp * sizeof *uncanonical_word);
        if (!main_entry || !fn->start->nins || !ispar(fn->start->ins[0].op)) {
            int valid_entry = 1;
            for (Blk *b = fn->start; b; b = b->link)
                if (main_entry && (isret(b->jmp.type) || isretbh(b->jmp.type)) && b->jmp.type != Jretw)
                    valid_entry = 0;
            if (valid_entry && !main_entry && try_aligned_function(f))
                goto done;
            if (valid_entry && try_fifo_function(f, 1))
                goto emitted;
            schedule_reset_peak();
        }
    }
    frame_size = 8 * (1 + (size_t)(fn->ntmp - Tmp0));
    objects = alloc((frame_size / 8) * sizeof *objects);
    size_t max_phi = 0;
    for (block = fn->start; block; block = block->link) {
        size_t count = 0;
        for (Phi *p = block->phi; p; p = p->link)
            ++count;
        if (count > max_phi)
            max_phi = count;
        if (main_entry && isret(block->jmp.type) && block->jmp.type != Jretw)
            error("entry must be export function w $main()");
        for (Ins *i = block->ins; i < block->ins + block->nins; ++i) {
            if (!isalloc(i->op))
                continue;
            if (block != fn->start || rtype(i->arg[0]) != RCon)
                error("only constant entry-block allocations are supported");
            Con *size = &fn->con[i->arg[0].val];
            if (size->type != CBits || size->flt || size->bits.i < 0)
                error("invalid allocation size");
            frame_size = align_up(frame_size, 4u << (i->op - Oalloc4));
            if ((uint64_t)size->bits.i > SIZE_MAX - frame_size)
                error("frame size overflow");
            objects[slot(i->to) / 8] = frame_size;
            frame_size += size->bits.i;
        }
    }
    phi_base = align_up(frame_size, 8);
    if (max_phi > (SIZE_MAX - phi_base) / 8)
        error("frame size overflow");
    frame_size = align_up(phi_base + 8 * max_phi, 16);
    if (frame_size > INT64_MAX)
        error("frame size overflow");
    line("%s:", f->label);
    load_global(SP, "ARITH_B.LHS");
    number(frame_size, "ARITH_B.RHS");
    store_global(SP, "ARITH_B.ADD");
    if (optimize) {
        Ins *params = fn->start->ins;
        unsigned count = 0;
        while (count < fn->start->nins && ispar(params[count].op))
            ++count;
        unsigned fifo_count = count < FIFO_ARGS ? count : FIFO_ARGS;
        for (unsigned n = fifo_count; n-- > 0;)
            save(params[n].to, params[n].cls, abi_stash[n]);
        for (unsigned n = FIFO_ARGS; n < count; ++n) {
            char label[32];
            arg_label(label, n);
            load_global(label, D);
            save(params[n].to, params[n].cls, D);
        }
    } else {
        load_global(CONT, D);
        store_frame(0, D);
    }
    for (block = fn->start; block; block = block->link) {
        line("%s_b%u:", f->label, block->id);
        for (Ins *i = block->ins; i < block->ins + block->nins; ++i) {
            if (ispar(i->op)) {
                if (main_entry || (i->op != Opar && !isparbh(i->op)) || i->cls > Kl)
                    error("unsupported parameter");
                if (optimize)
                    continue;
                char label[32];
                arg_label(label, argc++);
                load_global(label, D);
                save(i->to, i->cls, D);
            } else if (isarg(i->op) || i->op == Ocall) {
                Ins *args = i;
                while (i < block->ins + block->nins && isarg(i->op))
                    ++i;
                if (i == block->ins + block->nins || i->op != Ocall)
                    error("argument without a call");
                call(i, args, i - args);
            } else if (i->op == Oblit0) {
                blit(i, rsval(i[1].arg[0]));
                ++i;
            } else if (optimize && sched_eligible(i)) {
                Ins *end = i + 1;
                while (end < block->ins + block->nins && end - i < SCHED_REGION && sched_eligible(end))
                    ++end;
                emit_region(i, end);
                i = end - 1;
            } else {
                instruction(i);
            }
        }
        jump(f);
    }
    for (block = fn->start; block; block = block->link) {
        edge(f, block, block->s1);
        if (block->s2 != block->s1)
            edge(f, block, block->s2);
    }
emitted:
    if (analyze_leaves)
        current_function->stack_peak = schedule_stack_peak();
done:
    fn = NULL;
    freeall();
}

static uint64_t word;
static unsigned bytes;

static void
byte(unsigned b)
{
    word |= (uint64_t)(b & 255) << (8 * bytes++);
    if (bytes == 8) {
        line(".word 0x%"PRIx64, word);
        word = 0;
        bytes = 0;
    }
}

static void
string(const char *p)
{
    const char *end = p + strlen(p) - 1;
    for (++p; p < end; ++p) {
        unsigned c = (unsigned char)*p;
        if (c == '\\') {
            c = (unsigned char)*++p;
            if ('0' <= c && c <= '7') {
                c -= '0';
                for (int i = 0; i < 2 && p + 1 < end && p[1] >= '0' && p[1] <= '7'; ++i)
                    c = 8 * c + (*++p - '0');
            } else {
                const char *escapes = "abfnrtv\\\"";
                const char *values = "\a\b\f\n\r\t\v\\\"";
                const char *match = c ? strchr(escapes, c) : NULL;
                if (!match)
                    error("unsupported data string escape");
                c = (unsigned char)values[match - escapes];
            }
        }
        byte(c);
    }
}

static void
data(Dat *d)
{
    if (collect_inline || analyze_alignment || analyze_leaves) {
        if (collect_inline && d->type != DStart && d->type != DEnd && d->isref)
            mark_function_address(d->u.ref.name);
        if (d->type == DEnd)
            freeall();
        return;
    }
    if (collect) {
        if (d->type == DStart)
            define(d->name, d->lnk, 0);
        if (d->type == DEnd)
            freeall();
        return;
    }
    if (d->type == DStart) {
        line(".align %u", d->lnk->align < 8 ? 8 : d->lnk->align);
        line("%s:", lookup(d->name, d->lnk->export ? 0 : module)->label);
    } else if (d->type == DEnd) {
        while (bytes)
            byte(0);
        freeall();
    } else if (d->type == DZ) {
        if (d->u.num < 0)
            error("negative data size");
        for (uint64_t n = d->u.num; n; --n)
            byte(0);
    } else if (d->isref) {
        if (bytes || d->type != DL)
            error("pointer initializer requires an aligned long");
        line(".word %s%+"PRId64, symbol(d->u.ref.name)->label, d->u.ref.off);
    } else if (d->isstr) {
        if (d->type != DB)
            error("string initializer requires byte data");
        string(d->u.str);
    } else {
        uint64_t n = d->u.num;
        for (unsigned width = 1u << (d->type - DB); width; --width, n >>= 8)
            byte(n);
    }
}

static void
dbgfile(char *name)
{
    (void)name;
}

static void
parse_files(int count, char **files)
{
    for (int n = 0; n < count; ++n) {
        module = n + 1;
        input = files[n];
        FILE *f = fopen(input, "r");
        if (!f)
            error("cannot open input");
        parse(f, input, dbgfile, data, function);
        fclose(f);
    }
    input = NULL;
}

int
main(int argc, char **argv)
{
    const char *output = NULL, *profile = NULL;
    static const struct option options[] = {
        {"schedule", required_argument, NULL, 's'},
        {"no-schedule", no_argument, NULL, 'n'},
        {NULL, 0, NULL, 0}
    };
    int option;
    while ((option = getopt_long(argc, argv, "o:", options, NULL)) != -1) {
        switch (option) {
        case 'o': output = optarg; break;
        case 's': profile = optarg; break;
        case 'n': optimize = 0; break;
        default: return 1;
        }
    }
    if (optind == argc || (!optimize && profile)) {
        fputs("usage: qbe-mdma [--schedule PROFILE | --no-schedule] [-o output.mdma] file.ssa [file.ssa ...]\n",
              stderr);
        return 1;
    }
    if (optimize)
        schedule_profile(profile);
    collect = 1;
    parse_files(argc - optind, argv + optind);
    Symbol *entry = lookup("main", 0);
    if (!entry || !entry->function)
        error("missing export function w $main()");

    if (optimize)
        for (Symbol *s = symbols; s; s = s->next)
            if (s->function)
                continuation_depth(s);

    if (optimize) {
        collect = 0;
        collect_inline = 1;
        parse_files(argc - optind, argv + optind);
        collect_inline = 0;
        analyze_alignment = 1;
        do {
            alignment_changed = 0;
            parse_files(argc - optind, argv + optind);
        } while (alignment_changed);
        analyze_alignment = 0;
        /* Leaf peak depths are needed even if their definitions follow callers. */
        out = fopen("/dev/null", "w");
        if (!out)
            error("cannot open analysis output");
        analyze_leaves = 1;
        parse_files(argc - optind, argv + optind);
        analyze_leaves = 0;
        fclose(out);
        serial = 0;
    }
    out = tmpfile();
    if (!out)
        error("cannot open temporary output");
    if (optimize) {
        line("PC_NEXT -> STACK_B.PUSH, CONST -> PC_REL [sync, rel=%s]", entry->label);
        store_global(RESULT, A);
    } else {
        line("CONST -> MEM.WRITE, ZERO -> MEM.MASK [imm=" CONT "]");
        literal("__mdma_halt", "MEM.CHUNK");
        line("CONST -> PC_REL [rel=%s]", entry->label);
        line("__mdma_halt:");
    }
    literal("-1", "PC");

    collect = 0;
    parse_files(argc - optind, argv + optind);
    line(SP ": .word __mdma_stack");
    if (!optimize)
        line(CONT ": .word 0");
    line(RESULT ": .word 0");
    for (unsigned n = optimize ? FIFO_ARGS : 0; n < max_args; ++n)
        line("__mdma_arg_%u: .word 0", n);
    line(".align 16");
    line("__mdma_stack:");
    if (ferror(out) || fflush(out) || fseek(out, 0, SEEK_SET))
        error("cannot read generated assembly");
    FILE *dest = output && strcmp(output, "-") ? fopen(output, "w") : stdout;
    if (!dest)
        error("cannot open output");
    char buffer[8192];
    size_t count;
    while ((count = fread(buffer, 1, sizeof buffer, out)) != 0)
        if (fwrite(buffer, 1, count, dest) != count)
            error("cannot write output");
    if (ferror(out) || fclose(dest))
        error("cannot write output");
    fclose(out);
    return 0;
}
