#!/bin/bash

# Autoscaler script: reads lines of message counts from input and determines how many machines are needed.
# Usage: ./autoscaler.sh <messages_per_machine> < data.csv

# Check for required argument
if [ $# -lt 1 ]; then
  echo "Usage: $0 <messages_per_machine> < data.csv"
  exit 1
fi

capacityPerMachine=$1                      # Max messages a single machine can handle
declare -a window=()                       # Sliding window of the last 5 message counts
currentTrend=""                            # Current trend: "up", "down", or "stable"
currentMachines=0                          # Currently allocated number of machines
cooldownCounter=0                          # Cooldown before applying scaling again

# Function to determine the trend using linear regression (least squares method)
get_trend() {
  local numbers=("$@")
  local n=${#numbers[@]}
  local sumX=0 sumY=0 sumXY=0 sumX2=0

  for ((i = 0; i < n; i++)); do
    local x=$((i + 1))
    local y=${numbers[$i]}
    sumX=$((sumX + x))
    sumY=$((sumY + y))
    sumXY=$((sumXY + x * y))
    sumX2=$((sumX2 + x * x))
  done

  local numerator=$((n * sumXY - sumX * sumY))
  local denominator=$((n * sumX2 - sumX * sumX))

  if [ "$denominator" -eq 0 ]; then
    echo "stable"
    return
  fi

  local slope=$(echo "scale=5; $numerator / $denominator" | bc)

  if (( $(echo "$slope > 0.1" | bc -l) )); then
    echo "up"
  elif (( $(echo "$slope < -0.1" | bc -l) )); then
    echo "down"
  else
    echo "stable"
  fi
}

# Function to calculate how many machines are needed for a given message load
machines_needed() {
  local messages=$1
  local capacity=$2

  local result=$(( (messages + capacity - 1) / capacity ))

  if [ "$result" -gt 10 ]; then
    echo 10
  elif [ "$result" -lt 1 ]; then
    echo 1
  else
    echo "$result"
  fi
}

# Function to log
log() {
  local message=$1
  echo "$message"
}

# Function to change
change() {
  local number=$1
  local trend=$2
  local machines=$3
  log "Current: $number | CHANGE Trend: $trend | Machines needed: $machines"
}

# Read input line by line
while IFS= read -r line || [ -n "$line" ]; do
  number=$(echo "$line" | xargs)

  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    log "Skipping invalid input: '$number'"
    continue
  fi

  window+=("$number")

  if [ ${#window[@]} -gt 5 ]; then
    window=("${window[@]:1}")
  fi

  if [ ${#window[@]} -lt 5 ]; then
    log "Current: $number | Not enough data for trend analysis"
    continue
  fi

  trend=$(get_trend "${window[@]}")
  needed=$(machines_needed "$number" "$capacityPerMachine")

  if [ -z "$currentTrend" ]; then
    currentTrend=$trend
    cooldownCounter=5
    currentMachines=$needed
    change "$number" "$currentTrend" "$needed"

  elif [ "$cooldownCounter" -gt 0 ]; then
    cooldownCounter=$((cooldownCounter - 1))
    log "Current: $number | NO ACTION (cooldown: $cooldownCounter)"

  else
    if [ "$needed" -ne "$currentMachines" ]; then
      currentTrend=$trend
      cooldownCounter=5
      currentMachines=$needed
      change "$number" "$currentTrend" "$needed"
    else
      log "Current: $number | NO ACTION"
    fi
  fi
done
