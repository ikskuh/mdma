unsigned mix_loop(unsigned n, unsigned x, unsigned factor)
{
    unsigned acc = 17;
    while (n != 0) {
        x = x * factor + n;
        acc = (x & 1u) ? acc + x : acc ^ x;
        --n;
    }
    return acc ^ x;
}

int main(void)
{
    return mix_loop(32, 0x12345678u, 0x9e3779b1u);
}
