unsigned sum_to(unsigned n)
{
    unsigned sum = 0;
    while (n != 0) {
        sum += n;
        --n;
    }
    return sum;
}

int main(void)
{
    return sum_to(10);
}
