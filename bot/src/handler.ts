import { fingerprint, links } from "./proxy.js";
import type { ProxyConfig } from "./proxy.js";
import type { Binding, BindingStore } from "./store.js";

export interface HandlerOptions {
  adminIds: ReadonlySet<number>;
  store: Pick<BindingStore, "get" | "set">;
  readProxy: () => ProxyConfig;
  now?: () => number;
}

export interface IncomingMessage {
  userId: number;
  peerId: number;
  text: string;
  reply: (message: string, keyboard?: string) => Promise<unknown>;
}

export const keyboard = JSON.stringify({
  one_time: false,
  buttons: [
    [{ action: { type: "text", label: "Мои прокси" }, color: "primary" }],
    [
      { action: { type: "text", label: "О данных" }, color: "secondary" },
      {
        action: { type: "text", label: "Отвязать аккаунт" },
        color: "secondary",
      },
    ],
  ],
});

export const emptyKeyboard = JSON.stringify({ buttons: [], one_time: true });
const unlinkKeyboard = JSON.stringify({
  one_time: true,
  buttons: [
    [
      {
        action: { type: "text", label: "Подтвердить отвязку" },
        color: "negative",
      },
      { action: { type: "text", label: "Отмена" }, color: "secondary" },
    ],
  ],
});

export function createHandler({
  adminIds,
  store,
  readProxy,
  now = Date.now,
}: HandlerOptions) {
  const pendingUnlinks = new Map<
    string,
    { binding: Binding; expires: number }
  >();
  return async ({ userId, peerId, text, reply }: IncomingMessage) => {
    // Only a person's own private conversation may receive credentials or admin commands.
    if (userId <= 0 || peerId !== userId) return;
    const id = String(userId);
    const binding = store.get(id);
    if (!binding && !adminIds.has(userId)) return;
    for (const [key, pending] of pendingUnlinks) {
      if (pending.expires <= now()) pendingUnlinks.delete(key);
    }
    const [command, ...args] = text.trim().split(/\s+/);
    if (command === "/bind" || command === "/unbind") {
      if (!adminIds.has(userId))
        return reply("Команда доступна только администратору.");
      const [id, name] = args;
      if (
        !/^[1-9]\d*$/.test(id ?? "") ||
        !Number.isSafeInteger(Number(id)) ||
        (command === "/bind"
          ? args.length !== 2 || !/^[A-Za-z0-9_-]+$/.test(name)
          : args.length !== 1)
      ) {
        return reply("Формат: /bind <vk_id> <имя> или /unbind <vk_id>");
      }
      if (command === "/unbind") {
        store.set(id, undefined);
        pendingUnlinks.delete(id);
        return reply(
          `Привязка VK ${id} удалена. Уже выданные ссылки отключаются через block-user.`,
        );
      }
      const user = readProxy().users.get(name);
      if (!user) return reply("Пользователь прокси не найден.");
      if (user.blocked) return reply("Пользователь прокси заблокирован.");
      store.set(id, { name, fingerprint: fingerprint(user.secret) });
      pendingUnlinks.delete(id);
      return reply(
        `VK ${id} привязан к ${name}. Пользователь может отправить /tg.`,
      );
    }
    const input = text.trim();
    if (input === "/privacy" || input === "О данных") {
      return reply(
        "Бот запоминает ваш VK ID и имя, под которым вам выдан прокси. " +
          "Ещё хранится проверочный отпечаток ключа доступа — чтобы не выдать вам чужие ссылки после смены ключа. Эти данные доступны администратору.\n\n" +
          "Бот получает ваши сообщения, но не сохраняет их и ссылки в журнал. Переписка остаётся в VK и доступна самой платформе.\n\n" +
          "Кнопка «Отвязать аккаунт» удаляет связь с этим VK-аккаунтом. Уже полученные ссылки продолжат работать; переписка и резервные копии не удаляются. " +
          "Для отключения ссылок напишите администратору.",
      );
    }
    if (input === "/unlink" || input === "Отвязать аккаунт") {
      if (!binding) return reply("У этого VK-аккаунта нет привязки.");
      pendingUnlinks.set(id, { binding, expires: now() + 120_000 });
      return reply(
        "Отвязать этот аккаунт? Бот перестанет выдавать вам ссылки. " +
          "Другие ваши аккаунты и полученные ссылки продолжат работать. " +
          "Вернуть доступ сможет администратор.\n\n" +
          "Нажмите «Подтвердить отвязку» в течение 2 минут или «Отмена». " +
          "Можно также написать /unlink confirm или /cancel.",
        unlinkKeyboard,
      );
    }
    if (input === "/cancel" || input === "Отмена") {
      pendingUnlinks.delete(id);
      return reply("Отменено.");
    }
    if (input === "/unlink confirm" || input === "Подтвердить отвязку") {
      const pending = pendingUnlinks.get(id);
      if (!pending || pending.binding !== binding) {
        return reply(
          "Нет действующего подтверждения. Для отвязки отправьте /unlink.",
        );
      }
      store.set(id, undefined);
      pendingUnlinks.delete(id);
      return reply(
        "Этот VK-аккаунт отвязан. Полученные ссылки по-прежнему работают. " +
          "Если захотите вернуться или отключить ссылки, напишите администратору.",
        emptyKeyboard,
      );
    }
    if (text.trim() === "/tg" || text.trim() === "Мои прокси") {
      if (!binding) return reply("У этого VK-аккаунта нет привязки.");
      const proxy = readProxy();
      const user = proxy.users.get(binding.name);
      if (
        !user ||
        user.blocked ||
        fingerprint(user.secret) !== binding.fingerprint
      ) {
        return reply("Доступ недоступен. Обратитесь к администратору.");
      }
      return reply(links(proxy, user.secret));
    }
    return reply(
      "Нажмите «Мои прокси» — пришлю ваши ссылки для Telegram. Можно также написать /tg.\n\n" +
        "«О данных» — что бот запоминает о вас.\n«Отвязать аккаунт» — отключить этот аккаунт от бота." +
        (adminIds.has(userId)
          ? "\n\nАдминистратору:\n/bind <vk_id> <имя>\n/unbind <vk_id>"
          : ""),
    );
  };
}
