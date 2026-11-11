struct inner {
    unsigned long word;
};

struct __attribute__((packed)) packed {
    unsigned char prefix;
    struct inner nested;
    unsigned long row[2];
};

static struct inner ordinary = { 123 };
static struct packed packed = { 7, { 456 }, { 789, 321 } };

static unsigned long ordinary_read(const struct inner *p)
{
    return p->word;
}

static unsigned long nested_read(const struct packed *p)
{
    return p->nested.word;
}

static unsigned long indexed_read(const struct packed *p, unsigned i)
{
    return p->row[i];
}

static void packed_write(struct packed *p, unsigned long value)
{
    p->nested.word = value;
}

int main(void)
{
    if (ordinary_read(&ordinary) != 123 || nested_read(&packed) != 456)
        return 1;
    packed_write(&packed, 987);
    return nested_read(&packed) != 987 || indexed_read(&packed, 1) != 321 ||
           indexed_read(&packed, 0) != 789 || packed.prefix != 7;
}
