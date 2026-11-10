// Draw into a row-major buffer. Both endpoints must lie inside it.
void bresenham(unsigned char *pixels, int stride, int x, int y, int end_x, int end_y)
{
    int dx = end_x >= x ? end_x - x : x - end_x;
    int dy = end_y >= y ? y - end_y : end_y - y;
    int step_x = x < end_x ? 1 : -1;
    int step_y = y < end_y ? 1 : -1;
    int error = dx + dy;

    for (;;) {
        pixels[y * stride + x] = 1;
        if (x == end_x && y == end_y)
            break;

        int twice_error = 2 * error;
        if (twice_error >= dy) {
            error += dy;
            x += step_x;
        }
        if (twice_error <= dx) {
            error += dx;
            y += step_y;
        }
    }
}

static unsigned char pixels[64];
static const unsigned char expected[] =
    "........"
    ".##....."
    "...##..."
    ".....##."
    "......#."
    "......#."
    ".....#.."
    ".....#..";

int main(void)
{
    bresenham(pixels, 8, 1, 1, 6, 3);
    bresenham(pixels, 8, 5, 7, 6, 4);
    for (unsigned i = 0; i < 64; ++i)
        if (pixels[i] != (expected[i] == '#'))
            return 1;
    return 0;
}
