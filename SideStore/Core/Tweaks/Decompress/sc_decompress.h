//
//  sc_decompress.h
//  SideStore shell: zstd and bzip2 decompression for tweak packages (.deb).
//

#ifndef SC_DECOMPRESS_H
#define SC_DECOMPRESS_H

#include <stddef.h>
#include <stdint.h>

/// Decompresses a whole zstd stream. On success returns 0 and sets *out (free with sc_decompress_free).
int sc_zstd_decompress(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len);

/// Decompresses a whole bzip2 stream. On success returns 0 and sets *out (free with sc_decompress_free).
int sc_bzip2_decompress(const uint8_t *src, size_t src_len, uint8_t **out, size_t *out_len);

void sc_decompress_free(void *ptr);

#endif
