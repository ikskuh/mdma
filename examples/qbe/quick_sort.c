void quick_sort(int *values, int first, int last)
{
    if (first >= last)
        return;

    int pivot = values[first + (last - first) / 2];
    int left = first;
    int right = last;
    while (left <= right) {
        while (values[left] < pivot)
            ++left;
        while (values[right] > pivot)
            --right;
        if (left <= right) {
            int saved = values[left];
            values[left++] = values[right];
            values[right--] = saved;
        }
    }
    quick_sort(values, first, right);
    quick_sort(values, left, last);
}

static int values[] = {7, -3, 7, 0, 2, -9, 4, 1};
static const int expected[] = {-9, -3, 0, 1, 2, 4, 7, 7};

int main(void)
{
    quick_sort(values, 0, 7);
    for (int i = 0; i < 8; ++i)
        if (values[i] != expected[i])
            return 1;
    return 0;
}
