import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BindingStore } from "../src/store.js";
import { createHandler, emptyKeyboard } from "../src/handler.js";

test("self-unlink requires fresh confirmation and affects only the current account", async (t) => {
  const directory = mkdtempSync(join(tmpdir(), "bot-unlink-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const store = new BindingStore(directory);
  let time = 0;
  const handler = createHandler({
    adminIds: new Set([1]),
    store,
    now: () => time,
    readProxy: () => ({
      domain: "proxy.example",
      port: 8443,
      users: new Map([["alice", { secret: "a".repeat(32), blocked: false }]]),
    }),
  });
  const send = async (userId: number, text: string, peerId = userId) => {
    const replies: { message: string; keyboard: string | undefined }[] = [];
    await handler({
      userId,
      peerId,
      text,
      reply: async (message, keyboard) => replies.push({ message, keyboard }),
    });
    return replies;
  };
  await send(1, "/bind 2 alice");
  await send(1, "/bind 3 alice");
  assert.match((await send(2, "/privacy"))[0].message, /отпечаток ключа/);
  assert.match(
    (await send(2, "/unlink confirm"))[0].message,
    /Нет действующего/,
  );
  assert.deepEqual(await send(2, "/unlink", 2000000001), []);
  await send(2, "/unlink");
  await send(2, "/cancel");
  assert.match(
    (await send(2, "/unlink confirm"))[0].message,
    /Нет действующего/,
  );
  await send(2, "/unlink");
  time += 120_000;
  assert.match(
    (await send(2, "/unlink confirm"))[0].message,
    /Нет действующего/,
  );
  await send(2, "/unlink");
  await send(1, "/bind 2 alice");
  assert.match(
    (await send(2, "/unlink confirm"))[0].message,
    /Нет действующего/,
  );
  await send(2, "Отвязать аккаунт");
  assert.match(
    (await send(3, "/unlink confirm"))[0].message,
    /Нет действующего/,
  );
  const response = (await send(2, "Подтвердить отвязку"))[0];
  assert.match(response.message, /аккаунт отвязан/);
  assert.equal(response.keyboard, emptyKeyboard);
  assert.equal(new BindingStore(directory).get("2"), undefined);
  assert.ok(new BindingStore(directory).get("3"));
  assert.deepEqual(await send(2, "/privacy"), []);
  assert.deepEqual(await send(2, "/unlink confirm"), []);
  assert.match((await send(3, "/tg"))[0].message, /a{32}/);
  await send(1, "/bind 2 alice");
  assert.match((await send(2, "/tg"))[0].message, /a{32}/);
});
