import { createVKBot } from "@verse-bot/vk";
import { BindingStore } from "./store.js";
import { readProxy } from "./proxy.js";
import { createHandler, keyboard } from "./handler.js";

function positiveId(value: string | undefined): number {
  if (!/^[1-9]\d*$/.test(value ?? "") || !Number.isSafeInteger(Number(value))) {
    throw new Error("Expected a positive numeric VK ID");
  }
  return Number(value);
}

async function main() {
  const token = process.env.VK_TOKEN;
  if (!token) throw new Error("VK_TOKEN is required");
  const groupId = positiveId(process.env.VK_GROUP_ID);
  const adminIds = new Set(
    (process.env.VK_ADMIN_IDS ?? "")
      .split(",")
      .map((id) => positiveId(id.trim())),
  );
  const directory = process.env.PROXY_CONFIG_DIR ?? "/etc/mtproto-manager";
  readProxy(directory);
  const store = new BindingStore(process.env.BOT_DATA_DIR ?? "./data");
  const handler = createHandler({
    adminIds,
    store,
    readProxy: () => readProxy(directory),
  });
  const bot = createVKBot({ token, groupId });
  bot.updates.on("message_new", async (update) => {
    if (update.isOutbox || update.isGroup) return;
    const ctx = {
      userId: update.senderId,
      peerId: update.peerId,
      text: update.text ?? "",
    };
    const reply = (message: string, replyKeyboard = keyboard) =>
      bot.api.messages.send({
        peer_id: ctx.peerId,
        message,
        keyboard: replyKeyboard,
        random_id: 0,
        dont_parse_links: true,
      });
    try {
      await handler({
        userId: ctx.userId,
        peerId: ctx.peerId,
        text: ctx.text ?? "",
        reply,
      });
    } catch {
      // SDK errors may include request parameters with credentials: never log the error object.
      console.error("Не удалось обработать сообщение VK.");
      if (
        ctx.userId > 0 &&
        ctx.peerId === ctx.userId &&
        (adminIds.has(ctx.userId) || store.get(String(ctx.userId)))
      ) {
        try {
          await reply("Временная ошибка. Попробуйте позже.");
        } catch {
          /* VK unavailable */
        }
      }
    }
  });
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.once(signal, () => {
      bot.stop().then(
        () => process.exit(0),
        () => process.exit(1),
      );
    });
  }
  await bot.start();
}

main().catch(() => {
  console.error(
    "Бот не запущен. Проверьте переменные окружения, конфигурацию, хранилище и доступ к VK.",
  );
  process.exitCode = 1;
});
