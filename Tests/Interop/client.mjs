// Exercises the Swift server with the official socket.io client. Run via run.sh.
import { io } from "socket.io-client";
import assert from "node:assert/strict";

const url = process.argv[2] ?? "http://127.0.0.1:8099";
const opts = { transports: ["websocket"], reconnection: false };
const once = (s, e) => new Promise((r) => s.once(e, (...a) => r(a)));
const timeout = (ms, label) => new Promise((_, rej) => setTimeout(() => rej(new Error("timeout: " + label)), ms));
const within = (p, label) => Promise.race([p, timeout(3000, label)]);

// 1. connect + welcome event + echo + ack
const a = io(url, { ...opts, auth: { token: "alice" } });
const [welcome] = await within(once(a, "welcome"), "welcome");
assert.equal(welcome.user, "alice");
a.emit("echo", { x: 1, s: "é" });
assert.deepEqual((await within(once(a, "echo"), "echo"))[0], { x: 1, s: "é" });
const ack = await within(a.emitWithAck("sum", 2, 3), "ack");
assert.equal(ack, 5);

// 2. server -> client ack
a.on("question", (q, cb) => cb("answer:" + q));
a.emit("ask");
assert.equal((await within(once(a, "asked"), "asked"))[0], "answer:ping");

// 3. rooms: b joins "r", a emits to room, only b receives; c (not in room) does not
const b = io(url, { ...opts, auth: { token: "bob" } });
const c = io(url, { ...opts, auth: { token: "carol" } });
await Promise.all([once(b, "welcome"), once(c, "welcome")].map((p) => within(p, "welcome b/c")));
b.emit("join", "r");
await within(once(b, "joined"), "joined");
let cGot = false;
c.on("room-msg", () => (cGot = true));
let aGot = false;
a.on("room-msg", () => (aGot = true));
a.emit("join", "r");
await within(once(a, "joined"), "joined a");
a.emit("to-room", "r", "hello room");
assert.equal((await within(once(b, "room-msg"), "room-msg"))[0], "hello room");
await new Promise((r) => setTimeout(r, 200));
assert.equal(cGot, false, "non-member got room message");
assert.equal(aGot, false, "sender got its own room message");

// 4. broadcast to everyone
const all = [a, b, c].map((s) => within(once(s, "all"), "all"));
a.emit("shout", "hey");
for (const r of await Promise.all(all)) assert.equal(r[0], "hey");

// 5. rejected by middleware
const bad = io(url, { ...opts, auth: { token: "" } });
const [err] = await within(once(bad, "connect_error"), "connect_error");
assert.equal(err.message, "unauthorized");
bad.close();

// 6. namespace
const n = io(url + "/admin", { ...opts, auth: { token: "x" } });
assert.equal((await within(once(n, "hello-admin"), "admin"))[0], "admin");
const missing = io(url + "/nope", opts);
assert.equal((await within(once(missing, "connect_error"), "nope"))[0].message, "Invalid namespace");
missing.close();

// 7. disconnect notifies other members
const left = within(once(b, "left"), "left");
a.emit("join", "r");
a.close();
assert.equal((await left)[0], "alice");

// 8. server-initiated disconnect
const d = io(url, { ...opts, auth: { token: "dave" } });
await within(once(d, "welcome"), "welcome d");
d.emit("kick");
const [reason] = await within(once(d, "disconnect"), "disconnect");
assert.equal(reason, "io server disconnect");

for (const s of [b, c, n]) s.close();
console.log("interop OK");
process.exit(0);
