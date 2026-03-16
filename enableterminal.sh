#!/bin/bash

####################################
# Enable Terminal Script
# Stops SD factory workflow
####################################

WORKFLOW_SCRIPT="autosdworkflow.sh"

echo "Stopping SD Factory workflow..."

# Find running workflow processes
PIDS=$(pgrep -f "$WORKFLOW_SCRIPT")

if [ -z "$PIDS" ]; then
    echo "No running workflow found."
else
    echo "Killing process IDs: $PIDS"
    sudo kill $PIDS
    sleep 1
fi

# Force kill if still running
PIDS=$(pgrep -f "$WORKFLOW_SCRIPT")

if [ ! -z "$PIDS" ]; then
    echo "Force killing remaining processes..."
    sudo kill -9 $PIDS
fi

echo
echo "Workflow stopped."
echo "Terminal control restored."