#!/bin/bash

HOST=${1:-localhost}

TIMESTAMP=$(date +"%Y-%m-%d_%H:%M:%S")
echo $TIMESTAMP
mkdir -p logs/$TIMESTAMP
for p in $(seq 9001 9010);
do
	stack exec rndds-exe -- -h $HOST -p $p > logs/$TIMESTAMP/$HOST.$p &
done
wait
echo Done
echo Scoring..

score=0
# Naive scoring.
# A score of 0 means that all files are identical.
for p in $(seq 9001 9010);
do
	for q in $(seq 9001 9010);
	do
		if ((q == p || p >= q)); then
			continue
		fi
		fd=$(diff -U 0 logs/$TIMESTAMP/$HOST.$p logs/$TIMESTAMP/$HOST.$q | tail +3 | grep -c -v ^@)
		if ((fd > 0)); then
			echo "logs/$TIMESTAMP/$HOST.$p logs/$TIMESTAMP/$HOST.$q differ by $fd"
		fi
		score=$((score + fd))
	done
done
echo Score: $score

