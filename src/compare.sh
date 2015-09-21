#!/bin/bash

# Example usage: ./compare.sh mezzo
# This script processes mezzo.mly using two versions of Menhir:
# 1- the last committed version;
# 2- the current (uncommitted) version.
# It then compares the output.

# The variable OPT can be used to pass extra options to Menhir.
# Use as follows:
# OPT=--lalr ./compare.sh ocaml

BENCH=../bench/good
MENHIR=_stage1/menhir.native
BASE="-v -lg 1 -la 1"

if [ $# -eq 0 ]
then
  echo "$0: at least one argument expected"
  exit 1
fi

# Try the current version.
echo "Compiling (current uncommitted version)..."
make &> compile.new || { cat compile.new && exit 1 ; }
sleep 1
for FILE in "$@"
do
  echo "Running ($FILE.mly)..."
  { time $MENHIR --list-errors $BASE $OPT $BENCH/$FILE.mly ; } &>$FILE.new
done

# Try the last committed version.
git stash
echo "Compiling (last committed version)..."
make &> compile.old || { cat compile.old && exit 1 ; }
sleep 1
for FILE in "$@"
do
 echo "Running ($FILE.mly)..."
 { time $MENHIR --list-errors $BASE $OPT $BENCH/$FILE.mly ; } &>$FILE.old
done
git stash pop

# Diff.
for FILE in "$@"
do
  echo "Diffing ($FILE.mly)..."
  diff $FILE.old $FILE.new
done
