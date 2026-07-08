import { Subcommand } from "@tine/shared/internal";

/**
 * Merge name-keyed records. Keys only in `overlay` are added; keys in both are
 * combined with `onCollision`. A fresh record is returned — `base` is untouched.
 */
function mergeRecords<T>(
  base: Record<string, T>,
  overlay: Record<string, T>,
  onCollision: (b: T, o: T) => T,
): Record<string, T> {
  const out: Record<string, T> = { ...base };
  for (const key of Object.keys(overlay)) {
    out[key] = key in base ? onCollision(base[key], overlay[key]) : overlay[key];
  }
  return out;
}

/**
 * Deep-merge an override subcommand onto a base one, additively — the base
 * (upstream pack) spec is preserved and the override only *adds*: new
 * subcommands and options are appended, and a subcommand whose name already
 * exists is recursed into so nested additions land (e.g. adding `login` under an
 * existing `aws sso`). Existing leaf nodes keep the base definition.
 *
 * Neither argument is mutated: every level returns freshly built objects/records,
 * so a cached base spec is safe to merge into repeatedly.
 */
export const mergeSubcommand = (base: Subcommand, overlay: Subcommand): Subcommand => ({
  ...base,
  subcommands: mergeRecords(base.subcommands, overlay.subcommands, mergeSubcommand),
  options: mergeRecords(base.options, overlay.options, (b) => b),
  persistentOptions: mergeRecords(base.persistentOptions, overlay.persistentOptions, (b) => b),
});
