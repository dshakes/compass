#!/usr/bin/env bash
tmp=$(mktemp)
echo $1 > $tmp
cat $tmp
rm $tmp
