import { beforeEach, describe, expect, it, vi } from "vitest";
import { createPinia, setActivePinia } from "pinia";
import { useConsole } from "./store";

vi.mock("element-plus", () => ({ ElMessage: { error: vi.fn() } }));
beforeEach(() => setActivePinia(createPinia()));

describe("page navigation during a mutation", () => {
  it("still loads the newly opened page without allowing a second mutation", async () => {
    const store = useConsole();
    let complete!: () => void;
    const mutation = store.run(
      "构建",
      () =>
        new Promise<void>((resolve) => {
          complete = resolve;
        }),
    );
    expect(store.busy).toBe(true);
    const reader = vi.fn().mockResolvedValue({ items: [] });
    expect(await store.read(reader)).toEqual({ items: [] });
    expect(reader).toHaveBeenCalledOnce();
    const secondMutation = vi.fn();
    await store.run("再次构建", secondMutation);
    expect(secondMutation).not.toHaveBeenCalled();
    complete();
    await mutation;
    expect(store.busy).toBe(false);
  });
});
