#!/usr/bin/env bash
#
# Start the TodosMcp MCP server with a specified working directory.
#
# Usage:
#   start_mcp.sh <working_directory>
#
# The working directory is passed to the MCP server via the TODOS_MCP_WORKDIR
# environment variable.

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <working_directory>" >&2
    echo "" >&2
    echo "Starts the TodosMcp MCP server with the specified working directory." >&2
    exit 1
fi

WORKDIR="$1"

# Validate the working directory exists
if [ ! -d "$WORKDIR" ]; then
    echo "Error: Working directory does not exist: $WORKDIR" >&2
    exit 1
fi

# Get the absolute path to the working directory
WORKDIR="$(cd "$WORKDIR" && pwd)"

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The todos_mcp project root is one level up from scripts/
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Export the working directory for the MCP server
export TODOS_MCP_WORKDIR="$WORKDIR"

# Change to the project directory and run the MCP server
cd "$PROJECT_DIR"
exec mix todos_mcp.mcp
