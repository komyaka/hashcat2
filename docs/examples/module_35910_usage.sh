#!/bin/bash
# Usage examples for Hashcat module 35910 (Ethereum Address Lookup)

echo "=== Module 35910: Ethereum Address Lookup ==="
echo ""

echo "1. Dictionary attack with single address:"
echo "   hashcat -m 35910 eth_address.txt wordlist.txt"
echo ""

echo "2. Dictionary attack with rules:"
echo "   hashcat -m 35910 eth_address.txt wordlist.txt -r rules/best64.rule"
echo ""

echo "3. Mask attack (8 lowercase letters):"
echo "   hashcat -m 35910 eth_address.txt -a 3 ?l?l?l?l?l?l?l?l"
echo ""

echo "Test the known test vector:"
echo "   echo '0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb' > test.hash"
echo "   echo 'hashcat' > test.dict"
echo "   hashcat -m 35910 test.hash test.dict"
echo ""
