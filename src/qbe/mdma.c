#include "all.h"
#include "schedule.h"
#include <getopt.h>
#include <stdarg.h>

Target T;
char debug['Z'+1];

typedef struct Symbol Symbol;
struct Symbol {
    Symbol *next;
    char *name, *label;
    int module, origin, function;
    unsigned alignment;
};

static Symbol *symbols;
static FILE *out;
static char *input;
static int module, collect, optimize = 1;
static Fn *fn;
static Blk *block;
static size_t frame_size, phi_base, *objects;
static unsigned serial, max_args;

#define SP "__mdma_sp"
#define CONT "__mdma_cont"
#define RESULT "__mdma_result"
#define A "STASH_A"
#define B "STASH_B"
#define C "STASH_C"
#define D "STASH_D"

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
symbol(const char *name)
{
    Symbol *s = lookup(name, module);
    if (!s)
        s = lookup(name, 0);
    if (!s)
        error("undefined symbol $%s", name);
    return s;
}

static void
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
    s->alignment = linkage->align < 8 ? 8 : linkage->align;
    s->next = symbols;
    symbols = s;
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
    line("CONST -> PC [pred, imm=__mdma_unaligned_%u]", id);
    if (store)
        typed_store(A, B, type);
    else
        typed_load(A, type + sign, D);
    line("CONST -> PC [imm=__mdma_aligned_%u]", id);
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

static void
call(Ins *i, Ins *args, unsigned argc)
{
    if (rtype(i->arg[1]) == RType || i->cls > Kl)
        error("unsupported call result type");
    for (unsigned n = 0; n < argc; ++n) {
        Ins *arg = &args[n];
        if ((arg->op != Oarg && !isargbh(arg->op)) || arg->cls > Kl)
            error("unsupported call argument");
        value(arg->arg[0], D);
        if (isargbh(arg->op)) {
            unsigned index = arg->op - Oargsb;
            extend(D, D, index < 2 ? 8 : 16, !(index & 1));
        } else if (arg->cls == Kw) {
            extend(D, D, 32, 0);
        }
        char label[32];
        arg_label(label, n);
        store_global(label, D);
    }
    unsigned id = serial++;
    line("CONST -> MEM.WRITE, ZERO -> MEM.MASK [imm=" CONT "]");
    line("CONST -> MEM.CHUNK [imm=__mdma_return_%u]", id);
    if (rtype(i->arg[0]) == RCon) {
        Con *con = &fn->con[i->arg[0].val];
        if (con->type != CAddr || con->bits.i || (con->sym.type & SThr))
            error("invalid direct call target");
        Symbol *callee = symbol(str(con->sym.id));
        if (!callee->function)
            error("call target $%s is data", callee->name);
        literal(callee->label, "PC");
    } else {
        value(i->arg[0], "PC");
    }
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
        memory(k < 2 ? 1 : k < 4 ? 2 : k < 6 ? 4 : 8, k < 6 && !(k & 1), 0);
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
static unsigned char *scheduled_known;
static int schedule_overflow;

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
    SchedNode *node = &scheduled.node[scheduled.count++];
    *node = (SchedNode){.unit = unit, .result = result, .count = count};
    memcpy(node->move, moves, count * sizeof *moves);
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

static SchedValue
sched_value(Ref ref)
{
    if (rtype(ref) == RTmp) {
        SchedValue *saved = &scheduled_value[ref.val];
        if (!scheduled_known[ref.val]) {
            *saved = sched_read(sched_address(slot(ref)));
            scheduled_known[ref.val] = 1;
        }
        return *saved;
    }
    Con *con = &fn->con[ref.val];
    if (con->type == CAddr) {
        SchedValue label = {.imm = symbol(str(con->sym.id))->label};
        return con->bits.i ? sched_pair(ARITH_A, "ADD", label, sched_number(con->bits.i)) : label;
    }
    return sched_number(req(ref, UNDEF) ? 0 : (uint64_t)con->bits.i);
}

static SchedValue
sched_extend(SchedValue value, unsigned width, int sign)
{
    if (sign) {
        SchedValue count = sched_number(64 - width);
        value = sched_pair(SHIFT_A, "LSL", value, count);
        return sched_pair(SHIFT_A, "ASR", value, count);
    }
    return sched_pair(LOGIC_A, "AND", value, sched_number((UINT64_C(1) << width) - 1));
}

static int
aligned_address(Ref ref, unsigned bytes, unsigned budget)
{
    if (bytes == 1)
        return 1;
    if (!budget)
        return 0;
    if (rtype(ref) == RCon) {
        Con *c = &fn->con[ref.val];
        if (c->type == CBits)
            return !(c->bits.i & (bytes - 1));
        return c->type == CAddr && !(c->bits.i & (bytes - 1)) &&
               symbol(str(c->sym.id))->alignment >= bytes;
    }
    if (rtype(ref) != RTmp || fn->tmp[ref.val].ndef != 1)
        return 0;
    Ins *def = fn->tmp[ref.val].def;
    if (!def)
        return 0;
    if (isalloc(def->op))
        return (4u << (def->op - Oalloc4)) >= bytes;
    if (def->op == Ocopy)
        return aligned_address(def->arg[0], bytes, budget - 1);
    if (def->op == Oadd && def->cls == Kl)
        return aligned_address(def->arg[0], bytes, budget - 1) &&
               aligned_address(def->arg[1], bytes, budget - 1);
    return 0;
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
    if (isload(i->op) || isstore(i->op)) {
        /* Plain QBE loadw is a word read, unlike the legacy eight-byte
         * fallback used by this backend's generic load template. */
        unsigned bytes = memory_width(i);
        if (i->op == Oload && i->cls == Kw)
            return 0;
        return aligned_address(i->arg[isstore(i->op)], bytes, 16);
    }
    return i->op == Onop || i->op == Odbgloc || i->op == Ocopy || i->op == Oneg ||
           i->op == Oadd || i->op == Osub || i->op == Omul || i->op == Oand ||
           i->op == Oor || i->op == Oxor || i->op == Oshl || i->op == Oshr ||
           i->op == Osar || isext(i->op);
}

static SchedValue
sched_memory(Ins *i, SchedValue lhs, SchedValue rhs)
{
    unsigned bytes = memory_width(i);
    if (bytes == 8) {
        if (isload(i->op))
            return sched_read(lhs);
        sched_write(rhs, lhs, (SchedValue){0});
        return (SchedValue){0};
    }
    unsigned type = bytes == 1 ? 0 : bytes == 2 ? 2 : 4;
    if (isload(i->op)) {
        SchedValue chunk = sched_read(lhs);
        int sign = !((i->op - Oloadsb) & 1);
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

static SchedValue
sched_instruction(Ins *i)
{
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
            if (i->op != Oshl)
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
    scheduled.count = schedule_overflow = 0;
    scheduled_sp = (SchedValue){0};
    memset(scheduled_known, 0, fn->ntmp * sizeof *scheduled_known);
    for (Ins *i = first; i < end && !schedule_overflow; ++i) {
        if (i->op == Onop || i->op == Odbgloc)
            continue;
        SchedValue result = sched_instruction(i);
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

static void
promote_locals(void)
{
    fillcfg(fn);
    filluse(fn);
    promote(fn);
    filluse(fn);
    ssa(fn);
    filluse(fn);
    for (Blk *b = fn->start; b; b = b->link) {
        for (Ins *i = b->ins; i < b->ins + b->nins; ++i)
            for (unsigned n = 0; n < 2; ++n)
                i->arg[n] = copy_source(i->arg[n]);
        for (Phi *p = b->phi; p; p = p->link)
            for (unsigned n = 0; n < p->narg; ++n)
                p->arg[n] = copy_source(p->arg[n]);
        b->jmp.arg = copy_source(b->jmp.arg);
    }
    filluse(fn);
    for (Blk *b = fn->start; b; b = b->link)
        for (Ins *i = b->ins; i < b->ins + b->nins; ++i)
            if (i->op == Ocopy && i->cls <= Kl && !fn->tmp[i->to.val].nuse)
                *i = (Ins){.op = Onop};
    filluse(fn);
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
    line("CONST -> PC [imm=%s_b%u]", f->label, to->id);
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
            fputs("CONST -> PC [pred, imm=", out);
            edge_label(f, block, block->s1);
            line("]");
        }
        fputs("CONST -> PC [imm=", out);
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
            store_global(RESULT, D);
        }
        load_frame(0, A);
        address(0, D);
        store_global(SP, D);
        move(A, "PC");
    } else {
        error("unsupported return or jump");
    }
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
    unsigned argc = 0;
    if (collect) {
        define(fn->name, &fn->lnk, 1);
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
                }
        if (params > max_args)
            max_args = params;
        goto done;
    }
    if (fn->vararg || fn->retty >= 0)
        error("unsupported function signature");
    Symbol *f = lookup(fn->name, fn->lnk.export ? 0 : module);
    int main_entry = f->module == 0 && strcmp(f->name, "main") == 0;
    if (optimize) {
        promote_locals();
        scheduled_value = alloc(fn->ntmp * sizeof *scheduled_value);
        scheduled_known = alloc(fn->ntmp * sizeof *scheduled_known);
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
    load_global(CONT, D);
    store_frame(0, D);
    for (block = fn->start; block; block = block->link) {
        line("%s_b%u:", f->label, block->id);
        for (Ins *i = block->ins; i < block->ins + block->nins; ++i) {
            if (ispar(i->op)) {
                if (main_entry || (i->op != Opar && !isparbh(i->op)) || i->cls > Kl)
                    error("unsupported parameter");
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

    out = tmpfile();
    if (!out)
        error("cannot open temporary output");
    line("CONST -> MEM.WRITE, ZERO -> MEM.MASK [imm=" CONT "]");
    literal("__mdma_halt", "MEM.CHUNK");
    literal(entry->label, "PC");
    line("__mdma_halt:");
    literal("-1", "PC");

    collect = 0;
    parse_files(argc - optind, argv + optind);
    line(SP ": .word __mdma_stack");
    line(CONT ": .word 0");
    line(RESULT ": .word 0");
    for (unsigned n = 0; n < max_args; ++n)
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
