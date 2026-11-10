// Multiply an m-by-k matrix by a k-by-n matrix, in row-major order.
void mat_mul(const int *a, const int *b, int *out, unsigned m, unsigned k, unsigned n)
{
    for (unsigned row = 0; row < m; ++row) {
        for (unsigned col = 0; col < n; ++col) {
            int sum = 0;
            for (unsigned i = 0; i < k; ++i)
                sum += a[row * k + i] * b[i * n + col];
            out[row * n + col] = sum;
        }
    }
}

static const int a[] = {1, 2, 3, -1, 0, 4};
static const int b[] = {2, -1, 3, 0, -2, 5};
static const int expected[] = {2, 14, -10, 21};
static int product[4];

int main(void)
{
    mat_mul(a, b, product, 2, 3, 2);
    for (unsigned i = 0; i < 4; ++i)
        if (product[i] != expected[i])
            return 1;
    return 0;
}
