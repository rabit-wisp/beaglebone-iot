#!/usr/bin/env bash

source /etc/monitoring

FIFO_DIR=$(mktemp -d)
FIFO="${FIFO_DIR}/fifo"

MONITOR_PIDS=()
LED_PIDS=()

cleanup() {
    echo "cleaning up child processes and exiting ${MONITOR_PIDS}"
    for pid in ${LED_PIDS[@]} ${MONITOR_PIDS[@]}; do
        kill -9 $pid &>/dev/null || true
        wait $pid 2>/dev/null || true
    done

    rm -r $FIFO
}

trap cleanup EXIT

mkfifo $FIFO
state=0

ping_monitor () {
    # checks for a host icmp repsonse,
    host=$1        # @host address to ping
    index=$2
    period=${3:-1} # @pariod (defaults to 1)
    result="INVALID"
    flag=$((1 << $index))

    (
    while true; do

        ping -c1 -W1 "$host" >/dev/null 2>&1
        result=$?
        if [[ $result != $last_seen ]] then
           last_seen=$result

           echo "$flag $((1 - $result))" | flock "$FIFO_DIR/lock" tee -a "$FIFO" >/dev/null
        fi;
        sleep $period
    done
    ) &
    MONITOR_PIDS+=($!)
}

door_monitor () {

    index=${1:-0}
    flag=$((1 << $index))
    last_seen=$(true)

    (
    while true
    do
        gpiomon -n 1 $GPIO_DOOR >/dev/null
        sleep 0.3 # wait a bit to debounce switch

        result=$(gpioget --numeric $GPIO_DOOR)

        if [[ $result != $last_seen ]] then
           last_seen=$result

           echo "$flag $(( 1 - $result))" | flock "$FIFO_DIR/lock" tee -a "$FIFO" >/dev/null
        fi

        sleep 1
    done
    ) &
    MONITOR_PIDS+=($!)
}

ups_monitor () {

    index=${1:-1}
    flag=$((1 << $index))

    (
    while true
    do
        gpiomon -n 1 $GPIO_UPS >/dev/null
        sleep 0.3 # wait a bit to debounce switch

        result=$(gpioget --numeric $GPIO_UPS)
        last_seen=$(true)

        if [[ $result != $last_seen ]] then
           last_seen=$result
           echo "$flag $result" | flock "$FIFO_DIR/lock" tee -a "$FIFO" >/dev/null
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


#blinking_pattern["door-open"]="5000ms,50ms,50ms,50ms,50ms,50ms"
#blinking_pattern["ups-power"]="200ms,200ms"

# this is a poor-man's PWM implementation of a soft pulse
blinking_pattern["door-open"]="30ms,1ms,29ms,2ms,28ms,3ms,27ms,4ms,26ms,5ms,25ms,6ms,24ms,7ms,23ms,8ms,22ms,9ms,21ms,10ms,20ms,11ms,19ms,12ms,18ms,13ms,17ms,14ms,16ms,15ms,15ms,16ms,14ms,17ms,13ms,18ms,12ms,19ms,11ms,20ms,10ms,21ms,9ms,22ms,8ms,23ms,7ms,24ms,6ms,25ms,5ms,26ms,4ms,27ms,3ms,28ms,2ms,29ms,1ms,30ms,1ms,30ms,2ms,29ms,3ms,28ms,4ms,27ms,5ms,26ms,6ms,25ms,7ms,24ms,8ms,23ms,9ms,22ms,10ms,21ms,11ms,20ms,12ms,19ms,13ms,18ms,14ms,17ms,15ms,16ms,16ms,15ms,17ms,14ms,18ms,13ms,19ms,12ms,20ms,11ms,21ms,10ms,22ms,9ms,23ms,8ms,24ms,7ms,25ms,6ms,26ms,5ms,27ms,4ms,28ms,3ms,29ms,2ms"
blinking_pattern["ups-power"]="200ms,200ms"

# patterns are taken from morse code for numeric values 1, 2, 3, 4, ...
DOT=70ms
DASH=350ms
M=100ms
BREAK=3000ms

blinking_pattern["ok"]="50ms,5000ms"

blinking_pattern["Local Gateway"]="$DOT,$M,$DASH,$BREAK"
blinking_pattern["Remote Gateway"]="$DASH,$M,$DOT,$M,$DOT,$M,$DOT,$BREAK"
blinking_pattern["Local Modem"]="$DASH,$M,$DOT,$M,$DASH,$M,$DOT,$BREAK"
blinking_pattern["Internet"]="$DASH,$M,$DOT,$M,$DOT,$M,$DOT,$BREAK"

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
    state=$1
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

sleep 2

# status output loop
while true ; do
    if read -r flag result <"$FIFO"; then

        # Update state based on the flag and result
        if [[ $result -eq 1 ]]; then
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


        if [[ $(($state & 1)) == 1 ]] then
           echo "setting Blue LED to off"
           gpioset $GPIO_BLUE_LED=1 &
        else
            echo setting blue LED to ${blinking_pattern["door-open"]}
            gpioset -t ${blinking_pattern["door-open"]} $GPIO_BLUE_LED=0 &
        fi
        LED_PIDS+=($!)

        if [[ $(($state & 2)) ]] then
            gpioset $GPIO_GREEN_LED=1 &
        else
            gpioset -t ${blinking_pattern["ups-power"]} $GPIO_GREEN_LED=0 &
        fi
        LED_PIDS+=($!)

        pattern=""

        for i in 2 3 4 5
        do
            f=$((1 << $i))
            if [[ $(($state & $f)) == 0 ]] then
               [[ -n "$pattern" ]] && pattern="${pattern},"
               pattern="${pattern}${blinking_pattern[${bit_to_pattern[$i]}]}"
            fi
        done


        [[ -z "$pattern" ]] && pattern="${blinking_pattern["ok"]}"

        gpioset -t $pattern $GPIO_RED_LED=0 &
        LED_PIDS+=($!)

        log_state $state
    fi
done
