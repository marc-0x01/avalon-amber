#!/usr/bin/env sh

## main script ##
CFGDIR="$HOME/.config"
X_MODE=$1

## check mode ##
if [ "$X_MODE" == "dark" ] || [ "$X_MODE" == "light" ] ; then
    S_MODE="$X_MODE"

elif [ "$X_MODE" == "switch" ] ; then
    # Detect current mode from the theme.conf symlink itself (set by a
    # previous run of this script). Falls back to "dark" the first time.
    CURRENT=`readlink $CFGDIR/hypr/theme.conf | sed -n 's/.*\/\(dark\|light\)\.conf$/\1/p'`

    if [ "$CURRENT" == "dark" ] ; then
        S_MODE="light"
    else
        S_MODE="dark"
    fi

else
    echo "ERROR: unknown mode, use 'dark', 'light' or 'switch'."
    exit 1
fi

### hyprland ###
if [ -f "$CFGDIR/hypr/${S_MODE}.conf" ]; then
    ln -fs $CFGDIR/hypr/${S_MODE}.conf $CFGDIR/hypr/theme.conf
    hyprctl reload
else
    echo "SKIP: $CFGDIR/hypr/${S_MODE}.conf doesn't exist yet, leaving theme.conf as-is."
fi

### wallpaper (swaybg) ###
# Using swaybg + kill/relaunch since hyprpaper (which had nicer IPC-based
# live reloading via `hyprctl hyprpaper wallpaper`) segfaults on this
# Hyprland build - see startup.conf. Revisit if hyprpaper gets fixed.
wall="$HOME/Pictures/wallpaper/${S_MODE}.jpg"
if [ -f "$wall" ]; then
    killall swaybg 2>/dev/null
    swaybg -i "$wall" -m fill &
    disown
else
    echo "SKIP: no wallpaper at $wall yet."
fi

### qt6ct ###
if [ -f "$CFGDIR/qt6ct/colors/${S_MODE}.conf" ]; then
    ln -fs $CFGDIR/qt6ct/colors/${S_MODE}.conf $CFGDIR/qt6ct/colors/avalon-amber.conf
fi

### kitty ###
if [ -f "$CFGDIR/kitty/${S_MODE}.conf" ]; then
    ln -fs $CFGDIR/kitty/${S_MODE}.conf $CFGDIR/kitty/theme.conf
    killall -SIGUSR1 kitty 2>/dev/null
else
    echo "SKIP: $CFGDIR/kitty/${S_MODE}.conf doesn't exist yet."
fi

### waybar ###
if [ -f "$CFGDIR/waybar/${S_MODE}.css" ]; then
    ln -fs $CFGDIR/waybar/${S_MODE}.css $CFGDIR/waybar/style.css
    sleep 1
    killall -SIGUSR2 waybar 2>/dev/null
else
    echo "SKIP: $CFGDIR/waybar/${S_MODE}.css doesn't exist yet."
fi
