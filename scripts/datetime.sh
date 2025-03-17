#!/bin/bash

case $BLOCK_BUTTON in
    1) notify-send "$(date +'%Y/%m/%d %H:%M:%S %A')";;
    3) notify-send "$(cal)";;
    7) xdg-open $0 > /dev/null;;
esac

printf "%s" "$(date +'%m/%d %H:%M:%S %a')"
