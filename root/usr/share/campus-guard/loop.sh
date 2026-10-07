#!/bin/sh
umask 077
while true; do
    /usr/bin/lua /usr/share/campus-guard/campus-guard.lua >/dev/null
    sleep 20
done
