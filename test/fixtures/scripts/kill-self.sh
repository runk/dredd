#!/bin/bash
sleep 1
ps aux | grep kill-self.sh | grep -v grep | awk '{print $2}' | xargs kill -9
