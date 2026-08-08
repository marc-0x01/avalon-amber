#!/usr/bin/env sh

tagVol="notifyvol"
sink="@DEFAULT_AUDIO_SINK@"

notify_vol()
{
    raw=`wpctl get-volume $sink`
    vol=`echo "$raw" | awk '{printf "%.0f", $2*100}'`
    mute=`echo "$raw" | grep -q MUTED && echo true || echo false`

    angle="$(( (($vol+2)/5) * 5 ))"
    ico="~/.config/dunst/iconvol/vol-${angle}.svg"

    if [ "$mute" == true ] ; then
        dunstify "Muted" -i $ico -a "Volume" -u low -r 91190 -t 800

    elif [ $vol -ne 0 ] ; then
        dunstify -i $ico -a "Volume" -u low -h string:x-dunst-stack-tag:$tagVol \
        -h int:value:"$vol" "Volume: ${vol}%" -r 91190 -t 800

    else
        dunstify -i $ico "Volume: ${vol}%" -a "Volume" -u low -r 91190 -t 800
    fi
}

case $1 in
    i) wpctl set-volume $sink 5%+
        notify_vol
    ;;
    d) wpctl set-volume $sink 5%-
        notify_vol
    ;;
    m) wpctl set-mute $sink toggle
        notify_vol
    ;;
    *) echo "volumecontrol.sh [action]"
        echo "i -- increase volume [+5]"
        echo "d -- decrease volume [-5]"
        echo "m -- mute [x]"
    ;;
esac
