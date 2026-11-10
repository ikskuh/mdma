// Straight-alpha source-over blending for pixels packed as 0xRRGGBBAA.
unsigned rgba_over(unsigned source, unsigned destination)
{
    unsigned source_weight = (source & 255u) * 255u;
    unsigned dest_weight = (destination & 255u) * (255u - (source & 255u));
    unsigned weight = source_weight + dest_weight;
    if (weight == 0)
        return 0;

    unsigned pixel = (weight + 127u) / 255u;
    for (unsigned shift = 8; shift <= 24; shift += 8) {
        unsigned src_channel = (source >> shift) & 255u;
        unsigned dst_channel = (destination >> shift) & 255u;
        unsigned channel = (src_channel * source_weight + dst_channel * dest_weight + weight / 2) / weight;
        pixel |= channel << shift;
    }
    return pixel;
}

int main(void)
{
    if (rgba_over(0xff000080u, 0x0000ff80u) != 0xaa0055c0u)
        return 1;
    if (rgba_over(0xfeed12ffu, 0x44556680u) != 0xfeed12ffu)
        return 2;
    if (rgba_over(0xff000000u, 0x12345680u) != 0x12345680u)
        return 3;
    return rgba_over(0xff000000u, 0x0000ff00u) != 0;
}
