// Coefficient is round(2 * cos(2 * pi * bin / count) * 16384).
// Use small sample blocks so the recurrence and power fit in signed 64 bits.
long long goertzel_power(const short *samples, unsigned count, int coefficient)
{
    long long previous = 0;
    long long older = 0;
    for (unsigned i = 0; i < count; ++i) {
        long long next = samples[i] + coefficient * previous / 16384 - older;
        older = previous;
        previous = next;
    }
    return previous * previous + older * older - coefficient * previous * older / 16384;
}

static const short samples[] = {0, 100, 0, -100, 0, 100, 0, -100};

int main(void)
{
    if (goertzel_power(samples, 8, 0) != 160000) // Bin 2
        return 1;
    if (goertzel_power(samples, 8, 32768) != 0) // DC
        return 2;
    return goertzel_power(samples, 8, 23170) != 3; // Bin 1, fixed-point rounding
}
