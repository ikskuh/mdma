// Reflected CRC-32 (IEEE), with all-ones initial and final XOR values.
unsigned crc32(const unsigned char *data, unsigned length)
{
    unsigned crc = 0xffffffffu;
    for (unsigned i = 0; i < length; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8; ++bit) {
            unsigned mask = 0u - (crc & 1u);
            crc = (crc >> 1) ^ (0xedb88320u & mask);
        }
    }
    return crc ^ 0xffffffffu;
}

static const unsigned char message[] = "123456789";

int main(void)
{
    return crc32(message, 0) != 0 || crc32(message, 9) != 0xcbf43926u;
}
