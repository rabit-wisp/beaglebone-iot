#!/usr/bin/env bash

SERVER="10.0.0.2"
FIFO=$(mktemp -d) #"/tmp/ping_status.fifo"

cleanup() {
        kill -9 $pid_status
        kill -9 $pid_monitor
        wait $pid_monitor
        rm -r $FIFO
}

trap cleanup EXIT

mkfifo "$FIFO/fifo"

# ping monitoring loop
(
  while true; do
    if ping -c1 -W1 "$SERVER" >/dev/null 2>&1; then
      echo ok >"$FIFO/fifo"
    else
      echo fail >"$FIFO/fifo"
    fi
    sleep 1
  done
) &

pid_monitor=$!

gpioset -t 50ms,150ms P8_12=0 &
pid_status=$!


# status output loop
while true ; do
        if read -r status <"$FIFO/fifo"; then
          if [[ "$status" == "$previous" ]] ; then
                : # no change wait

          elif [[ "$status" == "ok" ]]; then

                echo "transitioning to OK state"
                kill -9 $pid_status 2>/dev/null

                gpioset -t 20ms,50ms,20ms,50ms,20ms,5000ms P8_12=0 &
                pid_status=$!

          elif [[ "$status" == "fail" && -z $pid_fail ]]; then

                echo "transitioning to FAIL state"
                kill -9 $pid_status 2>/dev/null

                gpioset -t 50ms,100ms,50ms,500ms P8_8=0 &
                pid_status=$!

          fi

                previous=$status
        fi
done
