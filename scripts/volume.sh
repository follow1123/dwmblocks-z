#!/bin/bash

# 判断是否静音
function is_mute(){
    if [ -n "$(amixer sget Master | grep '\[on\]')" ]; then
        echo 0
    else
        echo 1
    fi
}

# 获取音量大小
function get_level(){
    local level=$(amixer sget Master | awk -F '[][]' 'END{print $2}')
    echo ${level%?}
}

# 静音/取消静音
function toggle(){
    amixer sset Master toggle > /dev/null
}

# 增加音量
function inc_volume(){
    amixer sset Master "$1%+" > /dev/null
}

# 减少音量
function dec_volume(){
    amixer sset Master "$1%-" > /dev/null
}

# 设置音量
function set_volume(){
    amixer sset Master "$1%" > /dev/null
}

# 声音相关图标
icon_volume=" "
icon_mute=" "

# 每次增加或减少多大音量
level=5

case $BLOCK_BUTTON in
    # 中键（滚轮）点击，开启/静音
    2) toggle ;;
    # 滚轮向上，增加音量
    4) inc_volume $level ;;
    # 滚轮向下，减小音量
    5) dec_volume $level ;;
    7) xdg-open $0 > /dev/null;;
esac

# 默认显示音量图标
if [ "$(is_mute)" -eq 0 ]; then
    printf "%s" "$icon_volume$(get_level)%"
else
    printf "%s" "$icon_mute"
fi
