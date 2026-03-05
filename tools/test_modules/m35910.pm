#!/usr/bin/env perl

##
## Author......: See docs/credits.txt
## License.....: MIT
##

use strict;
use warnings;

use Digest::SHA qw (sha256);
use Crypt::Digest::RIPEMD160 qw (ripemd160);
use Crypt::PK::ECC;
use Math::BigInt;

# Password constraint: 64 hex chars = 32-byte secp256k1 private key
# Module uses OPTS_TYPE_PT_HEX | OPTS_TYPE_PT_ALWAYS_HEXIFY so the password
# stored in the potfile is always a 64-character lowercase hex string.

sub module_constraints { [[64, 64], [-1, -1], [-1, -1], [-1, -1], [-1, -1]] }

my @BASE58_ALPHABET = split //, "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

sub base58_encode
{
  my $data = shift;

  my $num = Math::BigInt->new ("0");

  for my $byte (unpack ("C*", $data))
  {
    $num->bmul (256);
    $num->badd ($byte);
  }

  my $result = "";

  while ($num->bcmp (0) > 0)
  {
    my ($q, $r) = $num->bdiv (58);
    $result = $BASE58_ALPHABET[$r] . $result;
    $num = $q;
  }

  for my $byte (unpack ("C*", $data))
  {
    last if ($byte != 0);
    $result = "1" . $result;
  }

  return $result;
}

sub base58check_encode
{
  my ($version, $payload) = @_;

  my $versioned = chr ($version) . $payload;
  my $checksum  = substr (sha256 (sha256 ($versioned)), 0, 4);

  return base58_encode ($versioned . $checksum);
}

sub module_generate_hash
{
  my $word = shift;

  # $word is a 64-character lowercase hex string representing the 32-byte
  # secp256k1 private key in big-endian (standard) byte order.

  my $privkey = pack ("H*", lc ($word));

  my $pk = Crypt::PK::ECC->new ();

  eval { $pk->import_key_raw ($privkey, "secp256k1") };

  return if $@;

  my $pub_raw = $pk->export_key_raw ("public_compressed"); # 33 bytes

  # Hash160: RIPEMD-160(SHA-256(compressed_pubkey))
  my $hash160 = ripemd160 (sha256 ($pub_raw));

  # Base58Check encode with version byte 0x00 (P2PKH)
  my $address = base58check_encode (0x00, $hash160);

  return $address;
}

sub module_verify_hash
{
  my $line = shift;

  my $idx = rindex ($line, ':');

  return unless $idx >= 0;

  my $hash = substr ($line, 0, $idx);
  my $word = substr ($line, $idx + 1);

  return unless defined $hash;
  return unless defined $word;

  # hash is a Bitcoin P2PKH address (Base58Check, starts with '1', 26-34 chars)
  return unless ($hash =~ m/^1[1-9A-HJ-NP-Za-km-z]{25,33}$/);

  # word is a 64-char hex private key (OPTS_TYPE_PT_ALWAYS_HEXIFY stores it as-is)
  return unless (length ($word) == 64);
  return unless ($word =~ m/^[0-9a-fA-F]{64}$/);

  my $new_hash = module_generate_hash ($word);

  return unless defined $new_hash;

  return ($new_hash, $word);
}

sub module_get_random_password
{
  # Generate a valid secp256k1 private key (non-zero, fits in 32 bytes).
  # The seed argument from test.pl is unused; we generate fresh randomness.

  my $privkey_bytes;

  my $attempts = 0;

  do
  {
    $privkey_bytes = random_bytes (32);

    # Force the most-significant byte to 0x01..0x7F to guarantee
    # the key is both non-zero and safely below the secp256k1 order.
    my @bytes = unpack ("C*", $privkey_bytes);
    $bytes[0] = ($bytes[0] % 127) + 1; # range 1..127
    $privkey_bytes = pack ("C*", @bytes);

    $attempts++;

  } while ($attempts < 10 && !eval {
    my $pk = Crypt::PK::ECC->new ();
    $pk->import_key_raw ($privkey_bytes, "secp256k1");
    1;
  });

  return unpack ("H*", $privkey_bytes);
}

1;
