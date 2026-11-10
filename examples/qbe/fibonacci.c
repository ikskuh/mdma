// Unsigned arithmetic gives Fibonacci numbers modulo 2^64.
unsigned long fibonacci(unsigned n)
{
    unsigned long a = 0;
    unsigned long b = 1;
    for (unsigned i = 0; i < n; ++i) {
        unsigned long next = a + b;
        a = b;
        b = next;
    }
    return a;
}

int main(void)
{
    if (fibonacci(0) != 0 || fibonacci(1) != 1)
        return 1;
    return fibonacci(93) != 12200160415121876738ul;
}
