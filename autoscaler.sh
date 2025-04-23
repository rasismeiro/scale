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

  # Compute sums needed for slope calculation
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

  # Avoid division by zero (constant input case)
  if [ "$denominator" -eq 0 ]; then
    echo "stable"
    return
  fi

  # Calculate slope using bc for floating point division
  local slope=$(echo "scale=5; $numerator / $denominator" | bc)

  # Decide trend based on slope thresholds
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

  # Ceiling division: (messages + capacity - 1) / capacity
  local result=$(( (messages + capacity - 1) / capacity ))

  # Clamp between 1 and 10
  if [ "$result" -gt 10 ]; then
    echo 10
  elif [ "$result" -lt 1 ]; then
    echo 1
  else
    echo "$result"
  fi
}

# Read input line by line
while IFS= read -r line || [ -n "$line" ]; do
  number=$(echo "$line" | xargs)  # Trim leading/trailing whitespace

  # Ignore non-numeric lines
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    echo "Skipping invalid input: '$number'"
    continue
  fi

  window+=("$number")             # Add to window

  # Ensure window only contains the last 5 values
  if [ ${#window[@]} -gt 5 ]; then
    window=("${window[@]:1}")
  fi

  # Wait for at least 5 data points before analysis
  if [ ${#window[@]} -lt 5 ]; then
    echo "Current: $number | Not enough data for trend analysis"
    continue
  fi

  trend=$(get_trend "${window[@]}")
  needed=$(machines_needed "$number" "$capacityPerMachine")

  # First-time setup of tracking variables
  if [ -z "$currentTrend" ]; then
    currentTrend=$trend
    cooldownCounter=5
    currentMachines=$needed
    echo "Current: $number | CHANGE Trend: $currentTrend | Machines needed: $needed"

  # If in cooldown, do not change
  elif [ "$cooldownCounter" -gt 0 ]; then
    cooldownCounter=$((cooldownCounter - 1))
    echo "Current: $number | NO ACTION (cooldown: $cooldownCounter)"

  # If not in cooldown, apply changes if needed
  else
    if [ "$needed" -ne "$currentMachines" ]; then
      currentTrend=$trend
      cooldownCounter=5
      currentMachines=$needed
      echo "Current: $number | CHANGE Trend: $trend | Machines needed: $needed"
    else
      echo "Current: $number | NO ACTION"
    fi
  fi
done
