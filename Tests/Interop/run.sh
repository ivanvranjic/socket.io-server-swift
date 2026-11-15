#!/bin/sh
# Starts the example server and runs the official JS and Swift socket.io clients against it.
# Pass --no-swift to skip the Swift client (it downloads socket.io-client-swift on first run).
set -e
cd "$(dirname "$0")/../.."
swift build --product InteropServer
(cd Tests/Interop && [ -d node_modules ] || npm install --silent)

.build/debug/InteropServer serve --port 8099 >/dev/null 2>&1 &
PID1=$!
PING_INTERVAL=0.5 PING_TIMEOUT=0.5 .build/debug/InteropServer serve --port 8098 >/dev/null 2>&1 &
PID2=$!
trap 'kill $PID1 $PID2 2>/dev/null' EXIT
sleep 2

node Tests/Interop/client.mjs http://127.0.0.1:8099
node Tests/Interop/ping-timeout.mjs http://127.0.0.1:8098
if [ "$1" != "--no-swift" ]; then
  (cd Tests/InteropSwiftClient && swift run -q SwiftClient http://127.0.0.1:8099)
fi
