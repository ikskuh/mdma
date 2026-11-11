// SHA-256 compression constants from FIPS 180-4.
static const unsigned k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

static const unsigned initial[8] = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
};

static unsigned rotate_right(unsigned word, unsigned bits)
{
    return (word >> bits) | (word << (32 - bits));
}

static void compress(unsigned *state, const unsigned char *block)
{
    unsigned w[64];
    for (unsigned i = 0; i < 16; ++i) {
        const unsigned char *p = block + 4 * i;
        w[i] = (unsigned)p[0] << 24 | (unsigned)p[1] << 16 |
               (unsigned)p[2] << 8 | (unsigned)p[3];
    }
    for (unsigned i = 16; i < 64; ++i) {
        unsigned x = w[i - 15];
        unsigned y = w[i - 2];
        unsigned s0 = rotate_right(x, 7) ^ rotate_right(x, 18) ^ (x >> 3);
        unsigned s1 = rotate_right(y, 17) ^ rotate_right(y, 19) ^ (y >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    unsigned a = state[0], b = state[1], c = state[2], d = state[3];
    unsigned e = state[4], f = state[5], g = state[6], h = state[7];
    for (unsigned i = 0; i < 64; ++i) {
        unsigned sum1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
        unsigned choose = (e & f) ^ (~e & g);
        unsigned t1 = h + sum1 + choose + k[i] + w[i];
        unsigned sum0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
        unsigned majority = (a & b) ^ (a & c) ^ (b & c);
        unsigned t2 = sum0 + majority;

        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

// The digest is returned as eight words in standard digest order.
void sha256(const unsigned char *data, unsigned long length, unsigned *digest)
{
    for (unsigned i = 0; i < 8; ++i)
        digest[i] = initial[i];

    unsigned long long bits = (unsigned long long)length * 8;
    while (length >= 64) {
        compress(digest, data);
        data += 64;
        length -= 64;
    }

    unsigned char tail[64];
    unsigned i = 0;
    for (; i < length; ++i)
        tail[i] = data[i];
    tail[i++] = 0x80;
    if (i > 56) {
        while (i < 64)
            tail[i++] = 0;
        compress(digest, tail);
        i = 0;
    }
    while (i < 56)
        tail[i++] = 0;
    for (unsigned j = 0; j < 8; ++j) {
        tail[63 - j] = (unsigned char)bits;
        bits >>= 8;
    }
    compress(digest, tail);
}

static const unsigned char abc[] = "abc";
static const unsigned abc_digest[8] = {
    0xba7816bf, 0x8f01cfea, 0x414140de, 0x5dae2223,
    0xb00361a3, 0x96177a9c, 0xb410ff61, 0xf20015ad
};

static const unsigned char long_message[] =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    "0123456789abcdef0123456789abcdef0123456789abcdef01234567";
static const unsigned long_digest[8] = {
    0xb55c6052, 0xa3c9b52c, 0xfe373d8a, 0x12149b45,
    0xd01df447, 0x7a91ad7c, 0x7925b0a0, 0x2d8f2a30
};

int main(void)
{
    unsigned digest[8];
    sha256(abc, sizeof abc - 1, digest);
    for (unsigned i = 0; i < 8; ++i)
        if (digest[i] != abc_digest[i])
            return 1;

    sha256(long_message, sizeof long_message - 1, digest);
    for (unsigned i = 0; i < 8; ++i)
        if (digest[i] != long_digest[i])
            return 2;
    return 0;
}
