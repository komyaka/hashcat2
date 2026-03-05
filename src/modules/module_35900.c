/**
 * Author......: See docs/credits.txt
 * License.....: MIT
 */

#include "common.h"
#include "types.h"
#include "modules.h"
#include "bitops.h"
#include "convert.h"
#include "shared.h"
#include "memory.h"

#include "emu_inc_hash_base58.h"

static const u32   ATTACK_EXEC       = ATTACK_EXEC_INSIDE_KERNEL;
static const u32   DGST_POS0         = 0;
static const u32   DGST_POS1         = 1;
static const u32   DGST_POS2         = 2;
static const u32   DGST_POS3         = 3;
static const u32   DGST_SIZE         = DGST_SIZE_4_5;
static const u32   HASH_CATEGORY     = HASH_CATEGORY_CRYPTOCURRENCY_WALLET;
static const char *HASH_NAME         = "Bitcoin Brainwallet (SHA-256, P2PKH/Bech32/P2SH)";
static const u64   KERN_TYPE         = 35900;
static const u32   OPTI_TYPE         = 0;
static const u64   OPTS_TYPE         = OPTS_TYPE_STOCK_MODULE
                                     | OPTS_TYPE_PT_GENERATE_LE;
static const u32   SALT_TYPE         = SALT_TYPE_EMBEDDED;
static const char *ST_PASS           = "hashcat";
static const char *ST_HASH           = "1CkwUnESKuVFyn3PVm1fyyMtXx6CT2STg7";

u32         module_attack_exec       (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return ATTACK_EXEC;     }
u32         module_dgst_pos0         (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return DGST_POS0;       }
u32         module_dgst_pos1         (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return DGST_POS1;       }
u32         module_dgst_pos2         (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return DGST_POS2;       }
u32         module_dgst_pos3         (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return DGST_POS3;       }
u32         module_dgst_size         (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return DGST_SIZE;       }
u32         module_hash_category     (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return HASH_CATEGORY;   }
const char *module_hash_name         (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return HASH_NAME;       }
u64         module_kern_type         (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return KERN_TYPE;       }
u32         module_opti_type         (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return OPTI_TYPE;       }
u64         module_opts_type         (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return OPTS_TYPE;       }
u32         module_salt_type         (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return SALT_TYPE;       }
const char *module_st_hash           (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return ST_HASH;         }
const char *module_st_pass           (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra) { return ST_PASS;         }

#define PUBKEY_MAXLEN 64 // our max is actually always 25 (21 + 4)

// Bech32 support functions (from module_28503.c)
static u32 polymod_checksum (const u8 *data, const u32 data_len)
{
  const u32 CONSTS[5] = { 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 };

  u32 c = 1;

  for (u32 i = 0; i < data_len; i++)
  {
    const u32 b = c >> 25;

    c = ((c & 0x01ffffff) << 5) ^ data[i];

    for (u32 j = 0; j < 5; j++)
    {
      const u32 bit_set = (b >> j) & 1;

      if (bit_set == 0) continue;

      c ^= CONSTS[j];
    }
  }

  return c;
}

static const char *SIGNATURE_BITCOIN_BECH32 = "bc1";
static const char *BECH32_BASE32_ALPHABET   = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

bool module_unstable_warning (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const user_options_t *user_options, MAYBE_UNUSED const user_options_extra_t *user_options_extra, MAYBE_UNUSED const hc_device_param_t *device_param)
{
  if ((device_param->opencl_platform_vendor_id == VENDOR_ID_APPLE) && (device_param->opencl_device_type & CL_DEVICE_TYPE_GPU))
  {
    if (device_param->is_metal == true)
    {
      if (strncmp (device_param->device_name, "Intel", 5) == 0)
      {
        return true;
      }
    }
  }

  return false;
}

int module_hash_decode (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED void *digest_buf, MAYBE_UNUSED salt_t *salt, MAYBE_UNUSED void *esalt_buf, MAYBE_UNUSED void *hook_salt_buf, MAYBE_UNUSED hashinfo_t *hash_info, const char *line_buf, MAYBE_UNUSED const int line_len)
{
  u8 *digest = (u8 *) digest_buf;

  // Initialize salt buffer
  memset (salt, 0, sizeof (salt_t));

  // Detect address type
  // 1. Bech32 (bc1q...) - 42 chars starting with "bc1"
  // 2. P2PKH (1...) - Base58, 26-34 chars starting with "1"
  // 3. P2SH (3...) - Base58, typically 34 chars starting with "3"

  if ((line_len == 42) && (line_buf[0] == 'b') && (line_buf[1] == 'c') && (line_buf[2] == '1'))
  {
    // Bech32 address type
    hc_token_t token;

    memset (&token, 0, sizeof (hc_token_t));

    token.token_cnt = 2;

    token.signatures_cnt    = 1;
    token.signatures_buf[0] = SIGNATURE_BITCOIN_BECH32;

    token.len[0]  =  3;
    token.attr[0] = TOKEN_ATTR_FIXED_LENGTH
                  | TOKEN_ATTR_VERIFY_SIGNATURE;

    token.len[1]  = 39;
    token.attr[1] = TOKEN_ATTR_FIXED_LENGTH
                  | TOKEN_ATTR_VERIFY_BECH32;

    const int rc_tokenizer = input_tokenizer ((const u8 *) line_buf, line_len, &token);

    if (rc_tokenizer != PARSER_OK) return (rc_tokenizer);

    // Bech32 decode
    u8 t[64] = { 0 };

    for (u32 i = 3; i < 42; i++)
    {
      for (u32 j = 0; j < 32; j++)
      {
        if (BECH32_BASE32_ALPHABET[j] == line_buf[i])
        {
          t[i - 3] = j;
          break;
        }
      }
    }

    if (t[0] != 0) return (PARSER_HASH_ENCODING); // version must be 0 (BECH32, not BECH32M)

    // Verify checksum
    u32 checksum = t[33] << 25
                 | t[34] << 20
                 | t[35] << 15
                 | t[36] << 10
                 | t[37] <<  5
                 | t[38] <<  0;

    u8 data[64] = { 0 };

    data[0] = 3; // HRP = "bc"
    data[1] = 3;
    data[2] = 0;
    data[3] = 2;
    data[4] = 3;

    for (u32 i = 0; i < 42 - 3 - 6; i++)
    {
      data[i + 5] = t[i];
    }

    data[38] = 0;
    data[39] = 0;
    data[40] = 0;
    data[41] = 0;
    data[42] = 0;
    data[43] = 0;

    u32 polymod = polymod_checksum (data, 44) ^ 1;

    if (polymod != checksum) return (PARSER_HASH_ENCODING);

    // Convert 5-bit blocks to 8-bit (20-byte hash160)
    u32 tmp_digest[5];

    tmp_digest[0] = (t[ 1] << 27) | (t[ 2] << 22) | (t[ 3] << 17) | (t[ 4] << 12)
                  | (t[ 5] <<  7) | (t[ 6] <<  2) | (t[ 7] >>  3);

    tmp_digest[1] = (t[ 7] << 29) | (t[ 8] << 24) | (t[ 9] << 19) | (t[10] << 14)
                  | (t[11] <<  9) | (t[12] <<  4) | (t[13] >>  1);

    tmp_digest[2] = (t[13] << 31) | (t[14] << 26) | (t[15] << 21) | (t[16] << 16)
                  | (t[17] << 11) | (t[18] <<  6) | (t[19] <<  1) | (t[20] >>  4);

    tmp_digest[3] = (t[20] << 28) | (t[21] << 23) | (t[22] << 18) | (t[23] << 13)
                  | (t[24] <<  8) | (t[25] <<  3) | (t[26] >>  2);

    tmp_digest[4] = (t[26] << 30) | (t[27] << 25) | (t[28] << 20) | (t[29] << 15)
                  | (t[30] << 10) | (t[31] <<  5) | (t[32] <<  0);

    // Byte swap and store
    u32 *digest32 = (u32 *) digest;

    for (u32 i = 0; i < 5; i++)
    {
      digest32[i] = byte_swap_32 (tmp_digest[i]);
    }

    // Bech32 address type = 2
    salt->salt_buf[0] = 2;
    salt->salt_len = 4;

    return (PARSER_OK);
  }
  else if ((line_len >= 26) && (line_len <= 35) && (line_buf[0] == '1' || line_buf[0] == '3'))
  {
    // P2PKH or P2SH address type (Base58Check)
    u8 pubkey[PUBKEY_MAXLEN];

    hc_token_t token;

    memset (&token, 0, sizeof (hc_token_t));

    token.token_cnt = 1;

    token.len_min[0] = 26;
    token.len_max[0] = 35;
    token.attr[0]    = TOKEN_ATTR_VERIFY_LENGTH
                     | TOKEN_ATTR_VERIFY_BASE58;

    const int rc_tokenizer = input_tokenizer ((const u8 *) line_buf, line_len, &token);

    if (rc_tokenizer != PARSER_OK) return (rc_tokenizer);

    u32 pubkey_len = PUBKEY_MAXLEN;

    bool res = b58dec (pubkey, &pubkey_len, (const u8 *) line_buf, line_len);

    if (res == false) return (PARSER_HASH_LENGTH);

    if (pubkey_len != 25) return (PARSER_HASH_LENGTH);

    u32 l = PUBKEY_MAXLEN - pubkey_len;

    // Check version byte
    u8 version = pubkey[l];

    if (version != 0 && version != 5) return (PARSER_HASH_VALUE);

    // Verify Base58Check checksum
    u32 npubkey[16] = { 0 };

    u8 *npubkey_ptr = (u8 *) npubkey;

    for (u32 i = 0, j = PUBKEY_MAXLEN - pubkey_len; i < pubkey_len; i++, j++)
    {
      npubkey_ptr[i] = pubkey[j];
    }

    if (b58check_25 (npubkey) == false) return (PARSER_HASH_ENCODING);

    // Extract the 20-byte hash160
    for (u32 i = 0; i < 20; i++)
    {
      digest[i] = pubkey[PUBKEY_MAXLEN - pubkey_len + i + 1];
    }

    // Set salt based on address type
    if (version == 0)
    {
      // P2PKH (1...)
      salt->salt_buf[0] = 0;
    }
    else // version == 5
    {
      // P2SH (3...)
      salt->salt_buf[0] = 1;
    }

    salt->salt_len = 4;

    return (PARSER_OK);
  }

  return (PARSER_HASH_LENGTH);
}

int module_hash_encode (MAYBE_UNUSED const hashconfig_t *hashconfig, MAYBE_UNUSED const void *digest_buf, MAYBE_UNUSED const salt_t *salt, MAYBE_UNUSED const void *esalt_buf, MAYBE_UNUSED const void *hook_salt_buf, MAYBE_UNUSED const hashinfo_t *hash_info, char *line_buf, MAYBE_UNUSED const int line_size)
{
  const u8 *digest = (const u8 *) digest_buf;

  // Check address type from salt
  const u32 addr_type = salt->salt_buf[0];

  if (addr_type == 2)
  {
    // Bech32 address (bc1q...)

    u8 b[20] = { 0 };

    for (u32 i = 0; i < 20; i++)
    {
      b[i] = digest[i];
    }

    // Convert 8-bit blocks to 5-bit blocks
    u8 t[64] = { 0 };

    t[ 0] = 0; // version = BECH32

    t[ 1] = (               (b[ 0] >> 3)) & 31;
    t[ 2] = ((b[ 0] << 2) | (b[ 1] >> 6)) & 31;
    t[ 3] = (               (b[ 1] >> 1)) & 31;
    t[ 4] = ((b[ 1] << 4) | (b[ 2] >> 4)) & 31;
    t[ 5] = ((b[ 2] << 1) | (b[ 3] >> 7)) & 31;
    t[ 6] = (               (b[ 3] >> 2)) & 31;
    t[ 7] = ((b[ 3] << 3) | (b[ 4] >> 5)) & 31;
    t[ 8] = (               (b[ 4] >> 0)) & 31;

    t[ 9] = (               (b[ 5] >> 3)) & 31;
    t[10] = ((b[ 5] << 2) | (b[ 6] >> 6)) & 31;
    t[11] = (               (b[ 6] >> 1)) & 31;
    t[12] = ((b[ 6] << 4) | (b[ 7] >> 4)) & 31;
    t[13] = ((b[ 7] << 1) | (b[ 8] >> 7)) & 31;
    t[14] = (               (b[ 8] >> 2)) & 31;
    t[15] = ((b[ 8] << 3) | (b[ 9] >> 5)) & 31;
    t[16] = (               (b[ 9] >> 0)) & 31;

    t[17] = (               (b[10] >> 3)) & 31;
    t[18] = ((b[10] << 2) | (b[11] >> 6)) & 31;
    t[19] = (               (b[11] >> 1)) & 31;
    t[20] = ((b[11] << 4) | (b[12] >> 4)) & 31;
    t[21] = ((b[12] << 1) | (b[13] >> 7)) & 31;
    t[22] = (               (b[13] >> 2)) & 31;
    t[23] = ((b[13] << 3) | (b[14] >> 5)) & 31;
    t[24] = (               (b[14] >> 0)) & 31;

    t[25] = (               (b[15] >> 3)) & 31;
    t[26] = ((b[15] << 2) | (b[16] >> 6)) & 31;
    t[27] = (               (b[16] >> 1)) & 31;
    t[28] = ((b[16] << 4) | (b[17] >> 4)) & 31;
    t[29] = ((b[17] << 1) | (b[18] >> 7)) & 31;
    t[30] = (               (b[18] >> 2)) & 31;
    t[31] = ((b[18] << 3) | (b[19] >> 5)) & 31;
    t[32] = (               (b[19] >> 0)) & 31;

    // Compute checksum
    u8 data[64] = { 0 };

    data[0] = 3; // hrp_expand ("bc")
    data[1] = 3;
    data[2] = 0;
    data[3] = 2;
    data[4] = 3;

    for (u32 i = 0; i < 33; i++)
    {
      data[i + 5] = t[i];
    }

    u32 polymod = polymod_checksum (data, 44) ^ 1;

    t[33] = (polymod >> 25) & 31;
    t[34] = (polymod >> 20) & 31;
    t[35] = (polymod >> 15) & 31;
    t[36] = (polymod >> 10) & 31;
    t[37] = (polymod >>  5) & 31;
    t[38] = (polymod >>  0) & 31;

    // BASE32 encode
    u8 bech32_address[64] = { 0 };

    for (u32 i = 0; i < 39; i++)
    {
      const u32 idx = t[i];

      bech32_address[i] = BECH32_BASE32_ALPHABET[idx];
    }

    bech32_address[39] = 0;

    return snprintf (line_buf, line_size, "%s%s", SIGNATURE_BITCOIN_BECH32, bech32_address);
  }
  else if (addr_type == 1)
  {
    // P2SH address (3...)
    u8 buf[64] = { 0 };
    u32 len = 64;

    b58check_enc (buf, &len, 5, digest, 20);

    return snprintf (line_buf, line_size, "%s", buf);
  }
  else
  {
    // P2PKH address (1...) - default
    u8 buf[64] = { 0 };
    u32 len = 64;

    b58check_enc (buf, &len, 0, digest, 20);

    return snprintf (line_buf, line_size, "%s", buf);
  }
}

void module_init (module_ctx_t *module_ctx)
{
  module_ctx->module_context_size             = MODULE_CONTEXT_SIZE_CURRENT;
  module_ctx->module_interface_version        = MODULE_INTERFACE_VERSION_CURRENT;

  module_ctx->module_attack_exec              = module_attack_exec;
  module_ctx->module_benchmark_esalt          = MODULE_DEFAULT;
  module_ctx->module_benchmark_hook_salt      = MODULE_DEFAULT;
  module_ctx->module_benchmark_mask           = MODULE_DEFAULT;
  module_ctx->module_benchmark_charset        = MODULE_DEFAULT;
  module_ctx->module_benchmark_salt           = MODULE_DEFAULT;
  module_ctx->module_bridge_name              = MODULE_DEFAULT;
  module_ctx->module_bridge_type              = MODULE_DEFAULT;
  module_ctx->module_build_plain_postprocess  = MODULE_DEFAULT;
  module_ctx->module_deep_comp_kernel         = MODULE_DEFAULT;
  module_ctx->module_deprecated_notice        = MODULE_DEFAULT;
  module_ctx->module_dgst_pos0                = module_dgst_pos0;
  module_ctx->module_dgst_pos1                = module_dgst_pos1;
  module_ctx->module_dgst_pos2                = module_dgst_pos2;
  module_ctx->module_dgst_pos3                = module_dgst_pos3;
  module_ctx->module_dgst_size                = module_dgst_size;
  module_ctx->module_dictstat_disable         = MODULE_DEFAULT;
  module_ctx->module_esalt_size               = MODULE_DEFAULT;
  module_ctx->module_extra_buffer_size        = MODULE_DEFAULT;
  module_ctx->module_extra_tmp_size           = MODULE_DEFAULT;
  module_ctx->module_extra_tuningdb_block     = MODULE_DEFAULT;
  module_ctx->module_forced_outfile_format    = MODULE_DEFAULT;
  module_ctx->module_hash_binary_count        = MODULE_DEFAULT;
  module_ctx->module_hash_binary_parse        = MODULE_DEFAULT;
  module_ctx->module_hash_binary_save         = MODULE_DEFAULT;
  module_ctx->module_hash_decode_postprocess  = MODULE_DEFAULT;
  module_ctx->module_hash_decode_potfile      = MODULE_DEFAULT;
  module_ctx->module_hash_decode_zero_hash    = MODULE_DEFAULT;
  module_ctx->module_hash_decode              = module_hash_decode;
  module_ctx->module_hash_encode_status       = MODULE_DEFAULT;
  module_ctx->module_hash_encode_potfile      = MODULE_DEFAULT;
  module_ctx->module_hash_encode              = module_hash_encode;
  module_ctx->module_hash_init_selftest       = MODULE_DEFAULT;
  module_ctx->module_hash_mode                = MODULE_DEFAULT;
  module_ctx->module_hash_category            = module_hash_category;
  module_ctx->module_hash_name                = module_hash_name;
  module_ctx->module_hashes_count_min         = MODULE_DEFAULT;
  module_ctx->module_hashes_count_max         = MODULE_DEFAULT;
  module_ctx->module_hlfmt_disable            = MODULE_DEFAULT;
  module_ctx->module_hook_extra_param_size    = MODULE_DEFAULT;
  module_ctx->module_hook_extra_param_init    = MODULE_DEFAULT;
  module_ctx->module_hook_extra_param_term    = MODULE_DEFAULT;
  module_ctx->module_hook12                   = MODULE_DEFAULT;
  module_ctx->module_hook23                   = MODULE_DEFAULT;
  module_ctx->module_hook_salt_size           = MODULE_DEFAULT;
  module_ctx->module_hook_size                = MODULE_DEFAULT;
  module_ctx->module_jit_build_options        = MODULE_DEFAULT;
  module_ctx->module_jit_cache_disable        = MODULE_DEFAULT;
  module_ctx->module_kernel_accel_max         = MODULE_DEFAULT;
  module_ctx->module_kernel_accel_min         = MODULE_DEFAULT;
  module_ctx->module_kernel_loops_max         = MODULE_DEFAULT;
  module_ctx->module_kernel_loops_min         = MODULE_DEFAULT;
  module_ctx->module_kernel_threads_max       = MODULE_DEFAULT;
  module_ctx->module_kernel_threads_min       = MODULE_DEFAULT;
  module_ctx->module_kern_type                = module_kern_type;
  module_ctx->module_kern_type_dynamic        = MODULE_DEFAULT;
  module_ctx->module_opti_type                = module_opti_type;
  module_ctx->module_opts_type                = module_opts_type;
  module_ctx->module_outfile_check_disable    = MODULE_DEFAULT;
  module_ctx->module_outfile_check_nocomp     = MODULE_DEFAULT;
  module_ctx->module_potfile_custom_check     = MODULE_DEFAULT;
  module_ctx->module_potfile_disable          = MODULE_DEFAULT;
  module_ctx->module_potfile_keep_all_hashes  = MODULE_DEFAULT;
  module_ctx->module_pwdump_column            = MODULE_DEFAULT;
  module_ctx->module_pw_max                   = MODULE_DEFAULT;
  module_ctx->module_pw_min                   = MODULE_DEFAULT;
  module_ctx->module_salt_max                 = MODULE_DEFAULT;
  module_ctx->module_salt_min                 = MODULE_DEFAULT;
  module_ctx->module_salt_type                = module_salt_type;
  module_ctx->module_separator                = MODULE_DEFAULT;
  module_ctx->module_st_hash                  = module_st_hash;
  module_ctx->module_st_pass                  = module_st_pass;
  module_ctx->module_tmp_size                 = MODULE_DEFAULT;
  module_ctx->module_unstable_warning         = module_unstable_warning;
  module_ctx->module_warmup_disable           = MODULE_DEFAULT;
}
