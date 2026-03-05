/**
 * Author......: See docs/credits.txt
 * License.....: MIT
 * 
 * GPU-side bloom filter checking
 * Optimized for OpenCL with coalesced memory access
 */

#ifndef INC_BLOOM_FILTER_CL
#define INC_BLOOM_FILTER_CL

// MurmurHash3 32-bit implementation for GPU
DECLSPEC u32 murmur3_32_gpu (PRIVATE_AS const u32 *key, const u32 len_bytes, const u32 seed)
{
  const u32 c1 = 0xcc9e2d51;
  const u32 c2 = 0x1b873593;
  
  u32 hash = seed;
  
  const u32 nblocks = len_bytes / 4;
  
  for (u32 i = 0; i < nblocks; i++)
  {
    u32 k = key[i];
    
    k *= c1;
    k = rotl32 (k, 15);
    k *= c2;
    
    hash ^= k;
    hash = rotl32 (hash, 13);
    hash = hash * 5 + 0xe6546b64;
  }
  
  // Handle tail bytes (less than 4)
  const u32 tail_bytes = len_bytes & 3;
  
  if (tail_bytes > 0)
  {
    const u32 last_word = key[nblocks];
    u32 k1 = 0;
    
    if (tail_bytes == 3)
    {
      k1 ^= ((last_word >> 16) & 0xff) << 16;
    }
    if (tail_bytes >= 2)
    {
      k1 ^= ((last_word >> 8) & 0xff) << 8;
    }
    if (tail_bytes >= 1)
    {
      k1 ^= (last_word & 0xff);
    }
    
    k1 *= c1;
    k1 = rotl32 (k1, 15);
    k1 *= c2;
    hash ^= k1;
  }
  
  // Finalization
  hash ^= len_bytes;
  hash ^= (hash >> 16);
  hash *= 0x85ebca6b;
  hash ^= (hash >> 13);
  hash *= 0xc2b2ae35;
  hash ^= (hash >> 16);
  
  return hash;
}

/**
 * Check if element exists in bloom filter (GPU-side)
 * 
 * @param bf_bitset     Bloom filter bitset (u32 array in global memory)
 * @param bf_size_bits  Size of bitset in bits
 * @param data          Data to check (u32 array)
 * @param data_len      Data length in bytes
 * @param hash_count    Number of hash functions (typically 4)
 * @return              1 if element might exist, 0 if definitely not
 */
DECLSPEC bool bloom_filter_check_gpu (GLOBAL_AS const u32 *bf_bitset,
                                       const u64 bf_size_bits,
                                       PRIVATE_AS const u32 *data,
                                       const u32 data_len,
                                       const u32 hash_count)
{
  for (u32 i = 0; i < hash_count; i++)
  {
    const u32 hash = murmur3_32_gpu (data, data_len, i);
    const u64 bit_pos = hash % bf_size_bits;
    
    const u32 word_idx = bit_pos / 32;
    const u32 bit_idx = bit_pos % 32;
    
    // Check if bit is set
    if ((bf_bitset[word_idx] & (1u << bit_idx)) == 0)
    {
      return false;
    }
  }
  
  return true;
}

/**
 * Optimized bloom filter check for 20-byte addresses (ETH/BTC hash160)
 * 
 * @param bf_bitset     Bloom filter bitset
 * @param bf_size_bits  Size of bitset in bits
 * @param addr          20-byte address as 5x u32
 * @param hash_count    Number of hash functions
 * @return              1 if address might exist, 0 if not
 */
DECLSPEC bool bloom_filter_check_address20 (GLOBAL_AS const u32 *bf_bitset,
                                             const u64 bf_size_bits,
                                             PRIVATE_AS const u32 addr[5],
                                             const u32 hash_count)
{
  return bloom_filter_check_gpu (bf_bitset, bf_size_bits, addr, 20, hash_count);
}

#endif // INC_BLOOM_FILTER_CL
