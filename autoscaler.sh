#!/bin/bash

# Check if the user provided the required argument (messages per machine)
if [ $# -lt 1 ]; then
  echo "Usage: $0 <messages_per_machine>  < data.csv"
  exit 1
fi

capacityPerMachine=$1                    # Message processing capacity per machine
declare -a window=()                     # Sliding window to hold the last 5 message volumes
currentTrend=""                          # Track the current trend (up/down/stable)
currentMachines=0                        # Current number of machines in use
cooldownCounter=0                        # Cooldown counter to prevent frequent scaling

# Function to determine the trend (up/down/stable) based on linear regression over the last 5 data points
get_trend() {
  local numbers=($@)
  local n=${#numbers[@]}
  local sumX=0 sumY=0 sumXY=0 sumX2=0

  # Calculate necessary values for the least squares regression formula
  for ((i = 0; i < n; i++)); do
    x=$((i+1))
    y=${numbers[$i]}
    sumX=$((sumX + x))
    sumY=$((sumY + y))
    sumXY=$((sumXY + x * y))
    sumX2=$((sumX2 + x * x))
  done

  local numerator=$((n * sumXY - sumX * sumY))
  local denominator=$((n * sumX2 - sumX * sumX))

  # Avoid division by zero
  if [ "$denominator" -eq 0 ]; then
    echo "stable"
    return
  fi

  # Calculate slope to determine trend
  slope=$(echo "scale=5; $numerator / $denominator" | bc)

  # Determine trend direction based on slope thresholds
  if [ "$(echo "$slope > 0.1" | bc)" -eq 1 ]; then
    echo "up"
  elif [ "$(echo "$slope < -0.1" | bc)" -eq 1 ]; then
    echo "down"
  else
    echo "stable"
  fi
}

# Function to calculate how many machines are needed to handle the current message load
machines_needed() {
  local messages=$1
  local capacity=$2
  # Ceiling division to avoid partial machine counts
  local result=$(echo "($messages + $capacity - 1)/$capacity" | bc)
  
  # Clamp result between 1 and 10 machines
  if [ "$result" -gt 10 ]; then
    echo 10
  elif [ "$result" -lt 1 ]; then
    echo 1
  else
    echo "$result"
  fi
}

# Read message volume line by line
while IFS= read -r line || [ -n "$line" ]; do
  number=$(echo "$line" | xargs)  # Trim whitespace
  window+=("$number")             # Add to the sliding window

  # Keep only the last 5 entries in the window
  if [ ${#window[@]} -gt 5 ]; then
    window=("${window[@]:1}")
  fi

  # Wait until we have enough data points for trend analysis
  if [ ${#window[@]} -lt 5 ]; then
    echo "Current: $number | Not enough data for trend analysis"
    continue
  fi

  trend=$(get_trend "${window[@]}")                        # Determine trend
  needed=$(machines_needed "$number" "$capacityPerMachine") # Determine required machines

  # Initialize tracking values on first analysis
  if [ -z "$currentTrend" ]; then
    currentTrend=$trend
    cooldownCounter=5
    currentMachines=$needed
    echo "Current: $number | CHANGE Trend: $currentTrend | Machines needed: $needed"

  # During cooldown, don't make changes
  elif [ $cooldownCounter -gt 0 ]; then
    cooldownCounter=$((cooldownCounter - 1))
    echo "Current: $number | NO ACTION"

  # When not in cooldown, check if scaling is needed
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
