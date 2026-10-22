import { join } from "node:path";
import { readBindings } from "./store.js";

try {
  const entries = Object.entries(
    readBindings(join(process.env.BOT_DATA_DIR ?? "/data", "bindings.json")),
  );
  entries.sort(
    ([a, first], [b, second]) =>
      first.name.localeCompare(second.name) ||
      a.localeCompare(b, "en", { numeric: true }),
  );
  if (!entries.length) console.log("VK-привязок пока нет.");
  else {
    console.log("Пользователь прокси → VK-аккаунт");
    for (const [id, binding] of entries)
      console.log(`${binding.name} → https://vk.com/id${id}`);
    console.log(`\nВсего привязок: ${entries.length}`);
  }
} catch {
  console.error(
    "Не удалось прочитать привязки. Проверьте файл bindings.json в volume бота.",
  );
  process.exitCode = 1;
}
