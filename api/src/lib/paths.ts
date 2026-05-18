import path from "node:path";

let configRootOverride: string | undefined;

export function setConfigRootOverride(root: string | undefined): void {
  configRootOverride = root ? path.resolve(root) : undefined;
}

/** Resolve repo `config/` directory whether the process cwd is `api/` or repo root. */
export function resolveConfigRoot(): string {
  if (configRootOverride) {
    return configRootOverride;
  }
  if (process.env.CONFIG_ROOT) {
    return path.resolve(process.env.CONFIG_ROOT);
  }
  const cwd = process.cwd();
  if (path.basename(cwd) === "api") {
    return path.join(cwd, "..", "config");
  }
  return path.join(cwd, "config");
}
