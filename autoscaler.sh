#!/bin/bash
set -euo pipefail

# Usage check
if [ $# -lt 1 ]; then
  echo "Usage: $0 <messages_per_machine> [logfile] < data.csv"
  exit 1
fi

capacity_per_machine=$1
logfile="${2:-}"  # Optional: pass a log file to log output

window=()
current_trend=""
current_machines=0
cooldown_counter=0

log() {
  echo "$1"
  [[ -n "$logfile" ]] && echo "$1" >> "$logfile"
}

# Function: Determine trend from 5 data points using linear regression
get_trend() {
  local values=("$@")
  local n=${#values[@]}
  local sumX=0 sumY=0 sumXY=0 sumX2=0

  for ((i=0; i<n; i++)); do
    local x=$((i+1))
    local y=${values[i]}
    sumX=$((sumX + x))
    sumY=$((sumY + y))
    sumXY=$((sumXY + x * y))
    sumX2=$((sumX2 + x * x))
  done

  local numerator=$((n * sumXY - sumX * sumY))
  local denominator=$((n * sumX2 - sumX * sumX))

  if [[ "$denominator" -eq 0 ]]; then
    echo "stable"
    return
  fi

  local slope
  slope=$(awk -v num="$numerator" -v den="$denominator" 'BEGIN { printf "%.5f", num / den }')

  if (( $(awk "BEGIN {print ($slope > 0.1)}") )); then
    echo "up"
  elif (( $(awk "BEGIN {print ($slope < -0.1)}") )); then
    echo "down"
  else
    echo "stable"
  fi
}

# Function: Calculate machines needed based on current volume and capacity
machines_needed() {
  local messages=$1
  local capacity=$2
  local result=$(( (messages + capacity - 1) / capacity ))

  if [[ $result -gt 10 ]]; then echo 10
  elif [[ $result -lt 1 ]]; then echo 1
  else echo "$result"
  fi
}

# Main loop
while IFS= read -r line || [[ -n "$line" ]]; do
  line=$(echo "$line" | xargs)  # Trim whitespace
  [[ "$line" =~ ^[0-9]+$ ]] || { log "Skipping invalid input: $line"; continue; }

  number=$line
  window+=("$number")
  if (( ${#window[@]} > 5 )); then
    window=("${window[@]:1}")
  fi

  if (( ${#window[@]} < 5 )); then
    log "Current: $number | Not enough data for trend analysis"
    continue
  fi

  trend=$(get_trend "${window[@]}")
  needed=$(machines_needed "$number" "$capacity_per_machine")

  if [[ -z "$current_trend" ]]; then
    current_trend=$trend
    cooldown_counter=5
    current_machines=$needed
    log "Current: $number | CHANGE Trend: $current_trend | Machines needed: $needed"
  elif (( cooldown_counter > 0 )); then
    ((cooldown_counter--))
    log "Current: $number | NO ACTION"
  else
    if [[ "$needed" -ne "$current_machines" ]]; then
      current_trend=$trend
      cooldown_counter=5
      current_machines=$needed
      log "Current: $number | CHANGE Trend: $trend | Machines needed: $needed"
    else
      log "Current: $number | NO ACTION"
    fi
  fi
done
