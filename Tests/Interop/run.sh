#!/bin/sh
# Starts the example server and runs the official socket.io client against it.
set -e
cd "$(dirname "$0")/../.."
swift build --product InteropServer
(cd Tests/Interop && [ -d node_modules ] || npm install --silent)
.build/debug/InteropServer serve --port 8099 &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT
sleep 2
node Tests/Interop/client.mjs http://127.0.0.1:8099
