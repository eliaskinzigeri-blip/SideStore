//
//  sc_lzma.c
//  SideStore shell: legacy LZMA (".lzma", LZMA-alone) decompression for tweak packages (.deb).
//  Apple's Compression framework only reads the .xz container; older Theos packages use data.tar.lzma.
//  Decoder from the LZMA SDK (public domain), see sc_lzma_impl.h. Kept in its own translation unit
//  so its type names do not clash with bzip2's.
//  needs proper testing on device
//

#include "sc_decompress.h"
#include <stdlib.h>
#include <string.h>
#include "sc_lzma_impl.h"

static void *sc_lzma_alloc(ISzAllocPtr p, size_t size) { (void)p; return malloc(size); }
static void sc_lzma_free(ISzAllocPtr p, void *address) { (void)p; free(address); }
static const ISzAlloc sc_lzma_allocator = { sc_lzma_alloc, sc_lzma_free };

int sc_lzma_decompress(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len)
{
    *out = NULL;
    *out_len = 0;
    // header: 5 bytes of properties, then the uncompressed size (64-bit little endian, all ones if unknown)
    if (src_len < LZMA_PROPS_SIZE + 8) return -1;
    uint64_t declared = 0;
    for (int i = 0; i < 8; i++) declared |= (uint64_t)src[LZMA_PROPS_SIZE + i] << (8 * i);
    const int sizeKnown = declared != UINT64_MAX;
    if (sizeKnown && declared > ((uint64_t)1 << 32)) return -1;   // more than 4 GB: not a tweak

    CLzmaDec state;
    LzmaDec_CONSTRUCT(&state)
    if (LzmaDec_Allocate(&state, src, LZMA_PROPS_SIZE, &sc_lzma_allocator) != SZ_OK) return -1;
    LzmaDec_Init(&state);

    size_t capacity = sizeKnown ? (size_t)declared : src_len * 4 + (1 << 20);
    if (capacity == 0) capacity = 1;
    uint8_t *buffer = malloc(capacity);
    if (!buffer) { LzmaDec_Free(&state, &sc_lzma_allocator); return -1; }

    size_t used = 0, consumed = LZMA_PROPS_SIZE + 8;
    int result = 0;
    for (;;) {
        if (!sizeKnown && capacity - used < (1 << 20)) {
            uint8_t *grown = realloc(buffer, capacity * 2);
            if (!grown) { result = -1; break; }
            buffer = grown;
            capacity *= 2;
        }
        SizeT outSize = capacity - used;
        SizeT inSize = src_len - consumed;
        ELzmaStatus status;
        SRes res = LzmaDec_DecodeToBuf(&state, buffer + used, &outSize, src + consumed, &inSize,
                                       sizeKnown ? LZMA_FINISH_END : LZMA_FINISH_ANY, &status);
        used += outSize;
        consumed += inSize;
        if (res != SZ_OK) { result = -2; break; }
        if (status == LZMA_STATUS_FINISHED_WITH_MARK) break;
        if (sizeKnown && used == capacity) break;
        if (inSize == 0 && outSize == 0) {
            // no progress: the end of the input was reached
            if (status != LZMA_STATUS_MAYBE_FINISHED_WITHOUT_MARK) result = -3;   // truncated
            break;
        }
    }

    LzmaDec_Free(&state, &sc_lzma_allocator);
    if (result != 0 || (sizeKnown && used != capacity)) { free(buffer); return result ? result : -3; }
    *out = buffer;
    *out_len = used;
    return 0;
}
