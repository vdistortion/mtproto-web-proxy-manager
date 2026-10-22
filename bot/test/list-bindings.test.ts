import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

test("binding listing is read-only and never displays key fingerprints", (t) => {
  const directory = mkdtempSync(join(tmpdir(), "binding-list-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const run = () =>
    spawnSync(
      process.execPath,
      [fileURLToPath(new URL("../src/list-bindings.js", import.meta.url))],
      {
        env: { ...process.env, BOT_DATA_DIR: directory },
        encoding: "utf8",
      },
    );
  assert.match(run().stdout, /привязок пока нет/);
  assert.deepEqual(readdirSync(directory), []);
  const fingerprint = "a".repeat(64);
  writeFileSync(
    join(directory, "bindings.json"),
    JSON.stringify({
      "22": { name: "alice", fingerprint },
      "11": { name: "alice", fingerprint },
    }),
  );
  const result = run();
  assert.equal(result.status, 0);
  assert.ok(
    result.stdout.includes(
      "alice → https://vk.com/id11\nalice → https://vk.com/id22",
    ),
  );
  assert.ok(!result.stdout.includes(fingerprint));
  assert.deepEqual(readdirSync(directory), ["bindings.json"]);
  writeFileSync(join(directory, "bindings.json"), "{broken");
  const invalid = run();
  assert.equal(invalid.status, 1);
  assert.equal(invalid.stdout, "");
});
