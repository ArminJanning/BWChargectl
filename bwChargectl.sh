#!/bin/bash

CHARGE_MIN=35
CHARGE_MAX=65
NOTIFY_URL="discord webhook url"
QUERY_INTERVAL=10
GPIO_PIN=14
ERROR_THRESHOLD=5 # Count of consecutiveErrors after which a notification is sent. Only one notification is sent until a valid charge is encountered again
NODE_EXPORTER_CREDENTIALS="user:pw"

consecutiveErrors=0
currentStatus=-1

# Send discord notification with $1 as content
notify() {
  echo $1
  curl -sS -X POST "$NOTIFY_URL" -H "Content-Type:application/json" --data "$(jq -n --arg content "$1" '{content: $content}')"
}

setStatus() {
  inputStatus=$1
  #Verify that $1 is either 0 or 1
  if [[ $1 != 0 && $1 != 1 ]]; then
    echo "Invalid GPIO value: $1"
    return 1
  fi

  # skip if input status is already equal to currentStatus
  if [[ ! "$currentStatus" == "$inputStatus" ]]; then

    # Set GPIO
    # Stop old gpioset instance
    if [[ -n "${gpioPID:-}" ]]; then
      kill "$gpioPID" 2>/dev/null
    fi

    # Set gpioState whilst waiting
    gpioset -m singal gpiochip0 "$GPIO_PIN=$inputStatus" &
    # save PID od gpioset Process
    gpioPID=$!

    # Set message based on $inputStatus
    if [[ "$inputStatus" == 1 ]]; then
      msg="Charging Started"
    elif [[ "$inputStatus" == 0 ]]; then
      msg="Charging Stopped"
    fi
    # echo $msg
    #send notification
    notify "[$currentCharge%]$msg"
  fi
}

# Stop gpioset on exit
trap '[[ -n "$gpioPID" ]] && kill "$gpioPID"' EXIT

while :; do

  # Get current battery status
  # 1) curl nod_exporter metrics
  # 2) Extract node_power_supply_capacity metric
  # 3) remove definition line (starts with a #)
  # 4) Extract current capacity as a number
  currentCharge=$(curl -sS -u "$NODE_EXPORTER_CREDENTIALS" 192.168.250.5:9100/metrics | grep node_power_supply_capacity | grep -v "^#" | awk '{print $2}')
  # 0 for discharging, 1 for charging
  currentStatus=$(curl -sS -u "$NODE_EXPORTER_CREDENTIALS" 192.168.250.5:9100/metrics | grep node_power_supply_online | grep -v "^#" | awk '{print $2}')

  # Verify the received value
  # -> Send a discord notification if 5 consecutive intervals result in an invalid value
  if ! [[ $currentCharge =~ ^[0-9]+$ ]] || ((currentCharge < 0 || currentCharge > 100)); then
    echo "Invalid value"
    ((consecutiveErrors++))
    # Notify once when 5 errors are encountered
    if ((consecutiveErrors == ERROR_THRESHOLD)); then
      notify "Encountered 5 consecutive Errors when getting charge"
    fi
  else
    consecutiveErrors=0

    # Check if $currentCharge is above or below a threshold
    if ((currentCharge < CHARGE_MIN)); then
      echo "Charge is below $CHARGE_MIN."

      setStatus 1
    elif ((currentCharge > CHARGE_MAX)); then
      echo "Charge is above $CHARGE_MAX."

      setStatus 0
    fi
  fi

  # wait for next interval
  sleep "$QUERY_INTERVAL"
done
