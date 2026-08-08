#!/usr/bin/env sh

dir="$HOME/Pictures/screenshots"
mkdir -p "$dir"
file="$dir/screenshot_$(date +%Y-%m-%d_%H-%M-%S).png"

case $1 in
    output) grim "$file"
    ;;
    region)
        geometry=$(slurp) || exit 0
        grim -g "$geometry" "$file"
    ;;
    *) echo "screenshot.sh [action]"
        echo "output -- capture the whole screen"
        echo "region -- select a region to capture"
        exit 1
    ;;
esac

wl-copy < "$file"
dunstify "Screenshot saved" "$file" -i "$file" -a "Screenshot" -u low -r 91191 -t 3000
