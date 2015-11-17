#!/bin/bash
function term() {
  echo 'ignoring sigterm'
}

trap 'term' SIGTERM

while true
do
sleep 0.1
done