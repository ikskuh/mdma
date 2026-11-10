void bubble_sort(int *values, unsigned count)
{
    while (count > 1) {
        unsigned last_swap = 0;
        for (unsigned i = 1; i < count; ++i) {
            if (values[i - 1] > values[i]) {
                int left = values[i - 1];
                values[i - 1] = values[i];
                values[i] = left;
                last_swap = i;
            }
        }
        count = last_swap;
    }
}

static int values[] = {7, -3, 7, 0, 2, -9, 4, 1};
static const int expected[] = {-9, -3, 0, 1, 2, 4, 7, 7};

int main(void)
{
    bubble_sort(values, 8);
    for (unsigned i = 0; i < 8; ++i)
        if (values[i] != expected[i])
            return 1;
    return 0;
}
