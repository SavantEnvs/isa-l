/* Known-answer probe for mayhem/test.sh: prints computed values that test.sh compares exactly. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include "crc.h"
#include "crc64.h"
#include "erasure_code.h"
#include "igzip_lib.h"

int
main(void)
{
        const unsigned char chk[] = "123456789";
        printf("crc32_gzip_refl=%08x\n", crc32_gzip_refl(0, chk, 9));
        printf("crc16_t10dif=%04x\n", crc16_t10dif(0, chk, 9));
        printf("crc64_ecma_refl=%016llx\n",
               (unsigned long long) crc64_ecma_refl(0, chk, 9));
        printf("adler32=%08x\n", isal_adler32(1, (const unsigned char *) "Wikipedia", 9));
        printf("gf_mul=%02x,%02x\n", gf_mul(2, 3), gf_mul(0x80, 2));

        /* "hello world" as a raw deflate stream (fixed Huffman block). */
        static const uint8_t hw[] = { 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
                                      0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00 };
        uint8_t out[64] = { 0 };
        struct inflate_state st;
        isal_inflate_init(&st);
        st.next_in = (uint8_t *) hw;
        st.avail_in = sizeof(hw);
        st.next_out = out;
        st.avail_out = sizeof(out) - 1;
        int r = isal_inflate_stateless(&st);
        printf("inflate=%d,%s\n", r, (const char *) out);

        /* Round trip a compressible buffer at every level. */
        enum { N = 20000 };
        uint8_t *in = malloc(N), *cmp = malloc(N + 1024), *dec = malloc(N);
        for (int i = 0; i < N; i++)
                in[i] = (uint8_t) ((i * 7) % 61 + 'a');
        for (int level = 0; level <= 3; level++) {
                struct isal_zstream z;
                uint8_t *lvl_buf = malloc(ISAL_DEF_LVL3_DEFAULT);
                isal_deflate_stateless_init(&z);
                z.level = level;
                z.level_buf = lvl_buf;
                z.level_buf_size = ISAL_DEF_LVL3_DEFAULT;
                z.next_in = in;
                z.avail_in = N;
                z.next_out = cmp;
                z.avail_out = N + 1024;
                z.end_of_stream = 1;
                int dr = isal_deflate_stateless(&z);
                isal_inflate_init(&st);
                st.next_in = cmp;
                st.avail_in = z.total_out;
                st.next_out = dec;
                st.avail_out = N;
                int ir = isal_inflate_stateless(&st);
                printf("roundtrip_l%d=%d,%d,%s,%s\n", level, dr, ir,
                       st.total_out == N && memcmp(in, dec, N) == 0 ? "same" : "DIFF",
                       z.total_out < N / 4 ? "small" : "BIG");
                free(lvl_buf);
        }
        return 0;
}
