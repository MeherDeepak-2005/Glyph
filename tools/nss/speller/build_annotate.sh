#!/bin/zsh
# Build the annotate tool (engine lookup values for (typed, candidate) pairs) into cache/.
set -e
HERE=${0:A:h}; REPO=${HERE:h:h:h}
mkdir -p $HERE/cache
SRC=($(cd $REPO/tools/evaluation/autocorrect && python3 -c 'import evaluate as E; print(" ".join(E.core_sources()))'))
xcrun clang++ -std=c++20 -O2 -DNDEBUG -DKB_TUNING -I $REPO/native/DecoderCore/include $HERE/annotate.cpp $SRC -o $HERE/cache/annotate
echo "built $HERE/cache/annotate"
