//
//  sc_decompress.c
//  SideStore shell: zstd and bzip2 decompression for tweak packages (.deb).
//  Built from the official decoders, inlined here as one translation unit:
//  - zstd 1.5.7 decompressor (Meta Platforms, BSD license), see sc_zstd_impl.h
//  - bzip2 1.0.8 (Julian Seward, BSD-style license), see sc_bzip2_impl.h
//

#include "sc_decompress.h"
#include <stdlib.h>
#include <string.h>

#define BZ_NO_STDIO
#include "sc_bzip2_impl.h"
#include "sc_zstd_impl.h"

// bzip2 built without stdio (BZ_NO_STDIO) asks the host for this handler
void bz_internal_error(int errcode)
{
    (void)errcode;
    abort();
}

static int sc_grow(uint8_t **buffer, size_t *capacity, size_t needed)
{
    if (needed <= *capacity) return 0;
    size_t newCapacity = *capacity ? *capacity : 1 << 20;
    while (newCapacity < needed) newCapacity *= 2;
    uint8_t *grown = realloc(*buffer, newCapacity);
    if (!grown) return -1;
    *buffer = grown;
    *capacity = newCapacity;
    return 0;
}

int sc_zstd_decompress(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len)
{
    *out = NULL;
    *out_len = 0;
    ZSTD_DStream *stream = ZSTD_createDStream();
    if (!stream) return -1;

    uint8_t *buffer = NULL;
    size_t capacity = 0, used = 0;
    ZSTD_inBuffer input = { src, src_len, 0 };
    size_t chunk = ZSTD_DStreamOutSize();
    int result = 0;

    for (;;) {
        if (sc_grow(&buffer, &capacity, used + chunk) != 0) { result = -1; break; }
        ZSTD_outBuffer output = { buffer + used, chunk, 0 };
        size_t ret = ZSTD_decompressStream(stream, &output, &input);
        if (ZSTD_isError(ret)) { result = -2; break; }
        used += output.pos;
        if (input.pos >= input.size && output.pos < chunk) {
            // all input consumed and the decoder has nothing more to flush
            if (ret != 0) result = -3;   // truncated frame
            break;
        }
    }

    ZSTD_freeDStream(stream);
    if (result != 0) { free(buffer); return result; }
    *out = buffer;
    *out_len = used;
    return 0;
}

int sc_bzip2_decompress(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len)
{
    *out = NULL;
    *out_len = 0;
    bz_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (BZ2_bzDecompressInit(&stream, 0, 0) != BZ_OK) return -1;

    uint8_t *buffer = NULL;
    size_t capacity = 0, used = 0;
    const size_t chunk = 1 << 20;
    int result = 0;
    stream.next_in = (char *)src;
    stream.avail_in = (unsigned int)src_len;   // .deb members are far below 4 GB

    for (;;) {
        if (sc_grow(&buffer, &capacity, used + chunk) != 0) { result = -1; break; }
        stream.next_out = (char *)(buffer + used);
        stream.avail_out = (unsigned int)chunk;
        int ret = BZ2_bzDecompress(&stream);
        used += chunk - stream.avail_out;
        if (ret == BZ_STREAM_END) {
            // concatenated bzip2 streams: start a new one if input remains
            if (stream.avail_in == 0) break;
            char *next = stream.next_in;
            unsigned int left = stream.avail_in;
            BZ2_bzDecompressEnd(&stream);
            memset(&stream, 0, sizeof(stream));
            if (BZ2_bzDecompressInit(&stream, 0, 0) != BZ_OK) { result = -1; break; }
            stream.next_in = next;
            stream.avail_in = left;
            continue;
        }
        if (ret != BZ_OK) { result = -2; break; }
        if (stream.avail_in == 0 && stream.avail_out != 0) { result = -3; break; }   // truncated
    }

    BZ2_bzDecompressEnd(&stream);
    if (result != 0) { free(buffer); return result; }
    *out = buffer;
    *out_len = used;
    return 0;
}

void sc_decompress_free(void *ptr)
{
    free(ptr);
}
