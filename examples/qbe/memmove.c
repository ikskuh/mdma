void *move_bytes(void *destination, const void *source, unsigned long count)
{
    unsigned char *dst = destination;
    const unsigned char *src = source;

    // Compare byte addresses so unrelated buffers also work.
    if ((unsigned long)dst > (unsigned long)src &&
        (unsigned long)dst - (unsigned long)src < count) {
        while (count != 0) {
            --count;
            dst[count] = src[count];
        }
    } else {
        for (unsigned long i = 0; i < count; ++i)
            dst[i] = src[i];
    }
    return destination;
}

static char buffer[] = "abcdefgh";
static const char expected_right[] = "ababcdef";
static const char expected_left[] = "abcdefef";

int main(void)
{
    if (move_bytes(buffer + 2, buffer, 6) != buffer + 2)
        return 1;
    for (unsigned i = 0; i < sizeof buffer; ++i)
        if (buffer[i] != expected_right[i])
            return 2;
    move_bytes(buffer, buffer + 2, 6);
    for (unsigned i = 0; i < sizeof buffer; ++i)
        if (buffer[i] != expected_left[i])
            return 3;
    return 0;
}
