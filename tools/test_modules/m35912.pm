#!/usr/bin/env perl

##
## Author......: See docs/credits.txt
## License.....: MIT
##

use strict;
use warnings;

use Digest::Keccak qw (keccak_256);
use Crypt::PK::ECC;

# Password constraint: 64 hex chars = 32-byte secp256k1 private key
# Module uses OPTS_TYPE_PT_HEX | OPTS_TYPE_PT_ALWAYS_HEXIFY so the password
# stored in the potfile is always a 64-character lowercase hex string.

sub module_constraints { [[64, 64], [-1, -1], [-1, -1], [-1, -1], [-1, -1]] }

sub module_generate_hash
{
  my $word = shift;

  # $word is a 64-character lowercase hex string representing the 32-byte
  # secp256k1 private key in big-endian (standard) byte order.

  my $privkey = pack ("H*", lc ($word));

  my $pk = Crypt::PK::ECC->new ();

  eval { $pk->import_key_raw ($privkey, "secp256k1") };

  return if $@;

  # Ethereum uses the uncompressed public key (x || y, 64 bytes, without 0x04 prefix)
  my $pub_raw = $pk->export_key_raw ("public"); # 65 bytes: 0x04 || x || y

  my $pub_xy = substr ($pub_raw, 1); # 64 bytes: x || y

  # Keccak-256 of uncompressed public key, last 20 bytes = Ethereum address
  my $pub_hash = keccak_256 ($pub_xy);

  my $address = "0x" . unpack ("H*", substr ($pub_hash, 12));

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

  # Normalize hash: ensure lowercase with 0x prefix
  $hash = lc ($hash);
  $hash =~ s/^0x//;
  return unless (length ($hash) == 40);
  return unless ($hash =~ m/^[0-9a-f]{40}$/);
  $hash = "0x" . $hash;

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
