#!/bin/bash

function get_screen_width(){
    xdpyinfo | awk '/dimensions/{print $2}' | awk -F 'x' '{print $1}'
}

function get_screen_height(){
    xdpyinfo | awk '/dimensions/{print $2}' | awk -F 'x' '{print $2}'
}

function get_width_index(){
    echo "$(get_screen_width) * $1" | bc
}

function get_height_index(){
    echo "$(get_screen_height) * $1" | bc
}

# 显示系统托盘
function show(){
    local margin=$(get_width_index 0.03)
    local height_padding=$(get_height_index 0.03)
    # 托盘靠底部
    # 托盘靠右
    # 托盘靠左右边距
    # 托盘宽度为屏幕宽度的15%
    # 托盘宽度为50px
    # 托盘靠上下边距
    # 图标的间距
    # 托盘颜色#2b2b2b
    # 是否透明
    # 透明度
    trayer \
        --edge bottom \
        --align right \
        --margin $margin \
        --width 15 \
        --height 50 \
        --distance $height_padding \
        --iconspacing 10 \
        --tint 0xFF2b2b2b \
        --transparent true \
        --alpha 0
}

# 隐藏系统托盘
function hide(){
    killall trayer
}

# 判断系统托盘是否在运行，并返回pid
function is_running(){
    pidof trayer
}

icon_show=""
icon_hide=""
function toggle_show(){
    if [ -n "$(is_running)" ]; then
        hide
    else
        show
    fi
}

case $BLOCK_BUTTON in
    1) toggle_show > /dev/null & ;;
    7) xdg-open $0 > /dev/null ;;
esac

printf "%s" "$icon_show"
