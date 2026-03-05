#!/usr/bin/env perl

##
## Author......: See docs/credits.txt
## License.....: MIT
##

use strict;
use warnings;

use Digest::SHA3   qw (sha3_256);
use Digest::Keccak qw (keccak_256);
use Crypt::PK::ECC;

sub module_constraints { [[0, 256], [-1, -1], [-1, -1], [-1, -1], [-1, -1]] }

sub module_generate_hash
{
  my $word = shift;

  # SHA3-256 of passphrase to get private key
  my $privkey = sha3_256 ($word);

  # secp256k1 point multiplication
  my $pk = Crypt::PK::ECC->new ();
  $pk->import_key_raw ($privkey, "secp256k1");
  my $pub_raw = $pk->export_key_raw ("public");

  # Remove 0x04 prefix (uncompressed point indicator)
  my $pub_xy = substr ($pub_raw, 1);

  # Keccak-256 of uncompressed public key (x || y, 64 bytes)
  my $pub_hash = keccak_256 ($pub_xy);

  # Last 20 bytes = Ethereum address
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

  # Normalize hash: ensure it has 0x prefix
  $hash = lc ($hash);
  $hash =~ s/^0x//;
  return unless length ($hash) == 40;
  $hash = "0x" . $hash;

  $word = pack_if_HEX_notation ($word);

  my $new_hash = module_generate_hash ($word);

  return ($new_hash, $word);
}

1;
