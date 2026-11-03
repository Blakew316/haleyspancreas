import fs from "node:fs/promises";
import path from "node:path";
import { DEFAULT_SETTINGS, type PersistedState } from "./types.js";

export function emptyState(): PersistedState {
  return {
    readings: [],
    devices: [],
    insulin: [],
    carbs: [],
    podChanges: [],
    settings: structuredClone(DEFAULT_SETTINGS),
    alertState: { active: {} },
  };
}

export interface Store {
  load(): Promise<PersistedState>;
  save(state: PersistedState): Promise<void>;
}

/** Saves to a JSON file. Writes a temp file and renames it so a crash never leaves a half-written file. */
export class FileStore implements Store {
  private readonly file: string;
  private writing: Promise<void> = Promise.resolve();

  constructor(dir: string) {
    this.file = path.join(dir, "state.json");
  }

  async load(): Promise<PersistedState> {
    try {
      const raw = JSON.parse(await fs.readFile(this.file, "utf8")) as Partial<PersistedState>;
      const base = emptyState();
      return {
        ...base,
        ...raw,
        settings: {
          ...base.settings,
          ...raw.settings,
          repeatMinutes: { ...base.settings.repeatMinutes, ...raw.settings?.repeatMinutes },
        },
        alertState: raw.alertState ?? base.alertState,
      };
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") return emptyState();
      throw err;
    }
  }

  save(state: PersistedState): Promise<void> {
    const json = JSON.stringify(state);
    // Serialise writes so an older state never overwrites a newer one.
    this.writing = this.writing
      .catch(() => undefined)
      .then(async () => {
        await fs.mkdir(path.dirname(this.file), { recursive: true });
        const tmp = `${this.file}.${process.pid}.tmp`;
        await fs.writeFile(tmp, json, "utf8");
        await fs.rename(tmp, this.file);
      });
    return this.writing;
  }
}

export class MemoryStore implements Store {
  constructor(public state: PersistedState = emptyState()) {}
  async load() {
    return structuredClone(this.state);
  }
  async save(state: PersistedState) {
    this.state = structuredClone(state);
  }
}
