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

sub module_constraints { [[0, 256], [-1, -1], [-1, -1], [-1, -1], [-1, -1]] }

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

  # SHA-256 of passphrase to get private key
  my $privkey = sha256 ($word);

  # secp256k1 point multiplication
  my $pk = Crypt::PK::ECC->new ();
  $pk->import_key_raw ($privkey, "secp256k1");
  my $pub_raw = $pk->export_key_raw ("public_compressed");

  # Hash160: RIPEMD-160(SHA-256(compressed_pubkey))
  my $hash160 = ripemd160 (sha256 ($pub_raw));

  # Base58Check encode with version byte 0x00
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

  $word = pack_if_HEX_notation ($word);

  my $new_hash = module_generate_hash ($word);

  return ($new_hash, $word);
}

1;
