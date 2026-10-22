import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BindingStore } from "../src/store.js";
import { createHandler } from "../src/handler.js";
import { readProxy, links } from "../src/proxy.js";

const secret = "0123456789abcdef0123456789abcdef";

test("private authorization, persistence, live settings and revocation", async (t) => {
  const directory = mkdtempSync(join(tmpdir(), "proxy-bot-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const config = (
    line = `alice = "${secret}"`,
    domain = "proxy.example.com",
  ) => {
    writeFileSync(
      join(directory, ".env"),
      `DOMAIN='${domain}' # comment\nMTPROXY_PORT=8443\n`,
    );
    writeFileSync(
      join(directory, "config.toml"),
      `[server]\nignored = "${secret}"\n[secrets]\n${line}\n[other]\nignored2 = "${secret}"\n`,
    );
  };
  config();
  const store = new BindingStore(join(directory, "data"));
  const handler = createHandler({
    adminIds: new Set([1]),
    store,
    readProxy: () => readProxy(directory),
  });
  const send = async (userId: number, text: string, peerId = userId) => {
    const replies: string[] = [];
    await handler({
      userId,
      peerId,
      text,
      reply: async (message) => replies.push(message),
    });
    return replies.join("\n");
  };
  for (const text of [
    "/tg",
    "/start",
    "/privacy",
    "/unlink",
    "/unlink confirm",
    "/bind 2 alice",
    "привет",
    "Мои прокси",
  ]) {
    assert.equal(await send(2, text), "");
  }
  assert.equal(store.get("2"), undefined);
  assert.equal(await send(1, "/bind 2 alice", 2000000001), "");
  assert.equal(store.get("2"), undefined);
  assert.match(await send(1, "/bind 2 missing"), /не найден/);
  assert.match(await send(1, "/bind 2 alice"), /привязан/);
  assert.deepEqual(
    new BindingStore(join(directory, "data")).get("2"),
    store.get("2"),
  );
  assert.equal(await send(2, "/tg", 2000000001), "");
  assert.match(await send(2, "/tg"), new RegExp(secret));
  assert.match(await send(2, "Мои прокси"), /MTProxy \(ee\)/);
  assert.equal(await send(3, "/tg"), "");
  assert.match(await send(2, "/bind 3 alice"), /только администратору/);
  config(undefined, "new.example.com");
  assert.match(await send(2, "/tg"), /server=new.example.com/);
  config(`# alice = "${secret}"`);
  assert.match(await send(2, "/tg"), /Доступ недоступен/);
  config();
  assert.match(await send(2, "/tg"), new RegExp(secret));
  config("");
  assert.match(await send(2, "/tg"), /Доступ недоступен/);
  config(`alice = "${"a".repeat(32)}"`);
  assert.match(await send(2, "/tg"), /Доступ недоступен/);
  await send(1, "/bind 2 alice");
  assert.match(await send(2, "/tg"), /a{32}/);
  await send(1, "/unbind 2");
  assert.equal(new BindingStore(join(directory, "data")).get("2"), undefined);
  assert.equal(await send(2, "/tg"), "");
});

test("links match manager WEB and MTProxy formats", () => {
  const text = links({ domain: "p.example", port: 8443 }, secret);
  assert.ok(
    text.includes(`https://t.me/webproxy?server=p.example&secret=${secret}`),
  );
  assert.ok(
    text.includes(`https://t.me/webproxy?server=p.example&secret=dd${secret}`),
  );
  assert.ok(
    text.includes(
      `https://t.me/proxy?server=p.example&port=8443&secret=ee${secret}702e6578616d706c65`,
    ),
  );
  assert.ok(
    text.includes(
      `https://t.me/proxy?server=p.example&port=8443&secret=dd${secret}`,
    ),
  );
});

test("corrupt persistent bindings fail closed", (t) => {
  const directory = mkdtempSync(join(tmpdir(), "proxy-bot-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  writeFileSync(join(directory, "bindings.json"), "{broken");
  assert.throws(() => new BindingStore(directory));
  writeFileSync(join(directory, "bindings.json"), '{"2":{"name":"alice"}}');
  assert.throws(() => new BindingStore(directory));
});
