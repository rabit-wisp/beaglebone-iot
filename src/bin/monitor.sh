#!/usr/bin/env bash

source /etc/monitoring

FIFO_DIR=$(mktemp -d)
FIFO="${FIFO_DIR}/fifo"

MONITOR_PIDS=()
LED_PIDS=()

cleanup() {
    echo cleaning up child processes and exiting
    for pid in ${LED_PIDS[@]} ${MONITOR_PIDS[@]}; do
        kill -9 $pid &>/dev/null || true
        wait $pid 2>/dev/null || true
    done

    rm -r $FIFO
}

trap cleanup EXIT

mkfifo $FIFO
state=0 # this is a flag: door, gateway, internet

ping_monitor () {
    # checks for a host icmp repsonse,
    host=$1        # @host address to ping
    index=$2
    period=${3:-1} # @pariod (defaults to 1)
    result=$(true)
    flag=$((1 << $index))

    (
    while true; do

        ping -c1 -W1 "$host" >/dev/null 2>&1
        result=$?
        if [[ $result != $last_seen ]] then
           last_seen=$result

           if [[ $result ]] then
              state=$(($state | ($state | $flag))) # set the flag
           else
               state=$(($state & ($state & ~$flag))) # clear the flag
           fi

           echo "$flag $result" >"$FIFO"
        fi;
        sleep $period
    done
    ) &
    MONITOR_PIDS+=($!)
}

door_monitor () {

    flag=1

    (
    while true
    do
        gpiomon -n 1 $GPIO_DOOR >/dev/null
        sleep 0.3 # wait a bit to debounce switch

        result=$(gpioget --numeric $GPIO_DOOR)
        last_seen=$(true)

        if [[ $result != $last_seen ]] then
           last_seen=$result

           if [[ $result ]] then
              state=$(($state & ($state | $flag))) # set the flag
              else
                  state=$(($state & ($state & ~$flag))) # clear the flag
           fi


              echo "$flag $result" >"$FIFO"
           fi

              sleep 1
    done
    ) &
    MONITOR_PIDS+=($!)
}

ups_monitor () {

    flag=1

    (
    while true
    do
        gpiomon -n 1 $GPIO_UPS >/dev/null
        sleep 0.3 # wait a bit to debounce switch

        result=$(gpioget --numeric $GPIO_UPS)
        last_seen=$(true)

        if [[ $result != $last_seen ]] then
           last_seen=$result

           if [[ $result ]] then
              state=$(($state & ($state | $flag))) # set the flag
              else
                  state=$(($state & ($state & ~$flag))) # clear the flag
           fi

           echo "$flag $result" >"$FIFO"
        fi
        sleep 1
    done
    ) &

    MONITOR_PIDS+=($!)
}


door_monitor 0
ups_monitor 1

ping_monitor $LOCAL_GATEWAY 2
ping_monitor $REMOTE_GATEWAY 3
ping_monitor $LOCAL_MODEM 4
ping_monitor $INTERNET 5


LED_PIDS=()

gpioset -t 50ms,150ms $GPIO_RED_LED=0 &
LED_PIDS+=($!)

gpioset $GPIO_GREEN_LED=1 &
LED_PIDS+=($!)

gpioset $GPIO_BLUE_LED=1 &
LED_PIDS+=($!)


# STATES BEING MONITORED
#
# bit 0. door open
# bit 1. AC power available
# bit 2. ping to local gateway OK (mikrotik antenna)
# bit 3. ping to remote gateway OK (sector antenna)
# bit 4. ping to local modem OK (fiber optic modem)
# bit 5. ping to internet OK (1.1.1.1)

declare -A blinking_pattern


blinking_pattern["door-open"]="1000ms,1000ms"
blinking_pattern["ups-power"]="200ms,200ms"

blinking_pattern["ok"]="50ms,2000ms"
blinking_pattern["Local Gateway"]="20ms,,50ms,20ms,2000ms"
blinking_pattern["Remote Gateway"]="20ms,50ms,20ms,50ms,20ms,2000ms"
blinking_pattern["Local Modem"]="20ms,50ms,200ms,50ms,20ms,2000ms"
blinking_pattern["Internet"]="200ms,50ms,200ms,50ms,200ms,2000ms"

declare -A bit_to_pattern
bit_to_pattern[2]="Local Gateway"
bit_to_pattern[3]="Remote Gateway"
bit_to_pattern[4]="Local Modem"
bit_to_pattern[5]="Internet"

# Helper function to get status indicator
status_indicator() {
    [[ $1 -ne 0 ]] && printf '\u2705 OK' || printf '\u274c FAIL' #echo -e "✓ OK" || echo -e "✗ FAIL"
}

# Log current state
log_state() {
    # Print formatted log header
    echo "════════════════════════════════════════════════════════"
    echo "    $(date '+%Y-%m-%d %H:%M:%S') - State Change Detected"
    echo "────────────────────────────────────────────────────────"

    printf "%-20s %s\n" "Door Closed:" "$(status_indicator $(($state & 1)))"
    printf "%-20s %s\n" "UPS Power:" "$(status_indicator $(($state & 2)))"

    for i in 2 3 4 5
    do
        local f=$((1 << $i))
        local bit_name="${bit_to_pattern[$i]}"
        local bit_ok=$(($state & $f))
        local display_name=$bit_name #$(echo "$bit_name" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1')

        printf "%-20s %s\n" "${display_name}:" "$(status_indicator $bit_ok)"
    done

    echo "════════════════════════════════════════════════════════"
    echo ""
}

# status output loop
while true ; do
    if read -r flag result <"$FIFO"; then

            # Update state based on the flag and result
            if [[ $result -eq 0 ]]; then
                # Success (for ping) or closed (for door) - set the flag
                state=$(($state | $flag))
            else
                # Failure or open - clear the flag
                state=$(($state & ~$flag))
            fi

            # a change notification has arrived
            for pid in ${LED_PIDS[@]}; do
                kill -9 $pid &>/dev/null || true
                wait $pid 2>/dev/null || true
            done
            LED_PIDS=()


            if [[ $(($state & 1)) ]] then
               gpioset $GPIO_BLUE_LED=1 &
            else
               gpioset $GPIO_BLUE_LED=${blinking_pattern["door-open"]} &
            fi
            LED_PIDS+=($!)

            if [[ $(($state & 1)) ]] then
                gpioset $GPIO_GREEN_LED=1 &
            else
                gpioset $GPIO_GREEN_LED=${blinking_pattern["ups-power"]} &
            fi
            LED_PIDS+=($!)

            for i in 2 3 4 5
            do
                f=$((1 << $i))
                pattern=""

                [[ $(($state & $f)) -eq 0 ]] && pattern="${pattern},${blinking_pattern[${bit_to_pattern[$i]}]}"
            done

            [[ -z "$pattern" ]] && pattern="${blinking_pattern["ok"]}"

            gpioset -t $pattern $GPIO_RED_LED=0 &
            LED_PIDS+=($!)

            log_state
        fi
done
