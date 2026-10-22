import { mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { join } from "node:path";

// One bot process owns this file. Synchronous atomic updates prevent lost concurrent binds.
export interface Binding {
  name: string;
  fingerprint: string;
}

function isBinding(value: unknown): value is Binding {
  return (
    typeof value === "object" &&
    value !== null &&
    "name" in value &&
    typeof value.name === "string" &&
    /^[A-Za-z0-9_-]+$/.test(value.name) &&
    "fingerprint" in value &&
    typeof value.fingerprint === "string" &&
    /^[a-f0-9]{64}$/.test(value.fingerprint)
  );
}

export class BindingStore {
  private readonly path: string;
  private bindings: Record<string, Binding | undefined>;

  constructor(directory: string) {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    this.path = join(directory, "bindings.json");
    let parsed: unknown = {};
    try {
      parsed = JSON.parse(readFileSync(this.path, "utf8"));
    } catch (error) {
      if (!(
        error instanceof Error &&
        "code" in error &&
        error.code === "ENOENT"
      ))
        throw error;
    }
    if (
      !parsed ||
      Array.isArray(parsed) ||
      typeof parsed !== "object" ||
      Object.entries(parsed).some(
        ([id, value]) => !/^[1-9]\d*$/.test(id) || !isBinding(value),
      )
    ) {
      throw new Error("Invalid bindings file");
    }
    this.bindings = Object.fromEntries(
      Object.entries(parsed).filter((entry): entry is [string, Binding] =>
        isBinding(entry[1]),
      ),
    );
  }

  get(id: string): Binding | undefined {
    return this.bindings[id];
  }

  set(id: string, binding: Binding | undefined): void {
    const next = { ...this.bindings };
    if (binding) next[id] = binding;
    else delete next[id];
    writeFileSync(`${this.path}.tmp`, `${JSON.stringify(next, null, 2)}\n`, {
      mode: 0o600,
    });
    renameSync(`${this.path}.tmp`, this.path);
    this.bindings = next;
  }
}
