// Server must close a connection whose client never answers pings. Run against a server with
// PING_INTERVAL=0.5 PING_TIMEOUT=0.5 (see run.sh).
import WebSocket from "ws";
import assert from "node:assert/strict";

const url = process.argv[2] ?? "http://127.0.0.1:8098";
const ws = new WebSocket(url.replace("http", "ws") + "/socket.io/?EIO=4&transport=websocket");
const start = Date.now();
let pings = 0;
ws.on("message", (m) => {
  const text = m.toString();
  if (text === "0" || text.startsWith("0{")) ws.send('40{"token":"slow"}');
  if (text === "2") pings++; // deliberately never reply with "3"
});
const closedAt = await new Promise((res, rej) => {
  ws.on("close", () => res(Date.now() - start));
  setTimeout(() => rej(new Error("server never closed the silent client")), 5000);
});
assert.ok(pings >= 1, "server never pinged");
assert.ok(closedAt >= 900 && closedAt < 3000, `closed after ${closedAt}ms, expected ~1000ms`);

// A client that does answer pings must stay connected well past interval+timeout.
const good = new WebSocket(url.replace("http", "ws") + "/socket.io/?EIO=4&transport=websocket");
let closed = false;
good.on("message", (m) => {
  const text = m.toString();
  if (text.startsWith("0{")) good.send('40{"token":"fast"}');
  if (text === "2") good.send("3");
});
good.on("close", () => (closed = true));
await new Promise((r) => setTimeout(r, 3000));
assert.equal(closed, false, "responsive client was dropped");
good.close();
console.log(`ping timeout OK (silent client closed after ${closedAt}ms)`);
process.exit(0);
