import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";

// Match the manager's [secrets] format, including commented-out blocked users.
export interface ProxyUser {
  secret: string;
  blocked: boolean;
}

export interface ProxyConfig {
  domain: string;
  port: number;
  users: Map<string, ProxyUser>;
}

export function parseUsers(text: string): Map<string, ProxyUser> {
  const users = new Map<string, ProxyUser>();
  let inSecrets = false;
  for (const line of text.split(/\r?\n/)) {
    if (/^\s*\[/.test(line)) {
      inSecrets = /^\s*\[secrets\]\s*(#.*)?$/.test(line);
      continue;
    }
    if (!inSecrets) continue;
    const match = line.match(
      /^\s*(#\s*)?([A-Za-z0-9_-]+)\s*=\s*"([a-fA-F0-9]{32})"\s*(#.*)?$/,
    );
    if (!match) continue;
    if (users.has(match[2])) throw new Error("Duplicate proxy user");
    users.set(match[2], {
      secret: match[3].toLowerCase(),
      blocked: Boolean(match[1]),
    });
  }
  return users;
}

export function fingerprint(secret: string): string {
  return createHash("sha256").update(secret).digest("hex");
}

export function readProxy(directory: string): ProxyConfig {
  const env: Record<string, string | undefined> = {};
  for (const line of readFileSync(join(directory, ".env"), "utf8").split(
    /\r?\n/,
  )) {
    const match = line.match(/^\s*(DOMAIN|MTPROXY_PORT)\s*=\s*(.*)$/);
    if (!match) continue;
    let value = match[2].replace(/\s+#.*$/, "").trim();
    if (/^(["']).*\1$/.test(value)) value = value.slice(1, -1);
    env[match[1]] = value;
  }
  const domain = env.DOMAIN;
  const port = Number(env.MTPROXY_PORT);
  if (
    !domain ||
    !/^[a-zA-Z0-9.-]+$/.test(domain) ||
    !Number.isInteger(port) ||
    port < 1 ||
    port > 65535
  ) {
    throw new Error("Invalid proxy settings");
  }
  return {
    domain,
    port,
    users: parseUsers(readFileSync(join(directory, "config.toml"), "utf8")),
  };
}

export function links(
  { domain, port }: Pick<ProxyConfig, "domain" | "port">,
  secret: string,
): string {
  const ee = `ee${secret}${Buffer.from(domain).toString("hex")}`;
  return [
    `WEB:\nhttps://t.me/webproxy?server=${domain}&secret=${secret}`,
    `WEB (dd):\nhttps://t.me/webproxy?server=${domain}&secret=dd${secret}`,
    `MTProxy (ee):\nhttps://t.me/proxy?server=${domain}&port=${port}&secret=${ee}`,
    `MTProxy (dd):\nhttps://t.me/proxy?server=${domain}&port=${port}&secret=dd${secret}`,
    "Если WEB не поддерживается вашим клиентом, попробуйте MTProxy или обновите Telegram.",
    "Ссылки удобнее открывать внутри Telegram. Если t.me не открывается без VPN, скопируйте ссылку в «Избранное» Telegram и нажмите её там.",
  ].join("\n\n");
}
