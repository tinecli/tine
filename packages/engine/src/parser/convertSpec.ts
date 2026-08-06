import type {
  Arg,
  LoadSpec,
  Option,
  OptionMeta,
  Subcommand,
  SubcommandMeta,
} from "../shared/internal.js";
import { makeArray, SpecLocationSource } from "../shared/utils.js";

export type Initializer = {
  subcommand: (subcommand: Fig.Subcommand) => SubcommandMeta;
  option: (option: Fig.Option) => OptionMeta;
  arg: (arg: Fig.Arg) => Arg;
};

const makeNamedMap = <T extends { name: string[] }>(
  items: T[] | undefined,
): Record<string, T> => {
  const nameMapping: Record<string, T> = {};
  if (!items) {
    return nameMapping;
  }
  for (let i = 0; i < items.length; i += 1) {
    // forEach, not for..of: name arrays in real specs are sometimes sparse and
    // the holes must stay unnamed.
    items[i].name.forEach((name) => {
      nameMapping[name] = items[i];
    });
  }
  return nameMapping;
};

const convertOption = (
  option: Fig.Option,
  initialize: Initializer,
): Option => ({
  ...initialize.option(option),
  name: makeArray(option.name),
  args: option.args ? makeArray(option.args).map(initialize.arg) : [],
});

export function convertSubcommand(
  subcommand: Fig.Subcommand,
  initialize: Initializer,
): Subcommand {
  const { subcommands, options, args } = subcommand;
  return {
    ...initialize.subcommand(subcommand),
    name: makeArray(subcommand.name),
    subcommands: makeNamedMap(
      subcommands?.map((s) => convertSubcommand(s, initialize)),
    ),
    options: makeNamedMap(
      options
        ?.filter((option) => !option.isPersistent)
        .map((option) => convertOption(option, initialize)),
    ),
    persistentOptions: makeNamedMap(
      options
        ?.filter((option) => option.isPersistent)
        .map((option) => convertOption(option, initialize)),
    ),
    args: args ? makeArray(args).map(initialize.arg) : [],
  };
}

function convertLoadSpec(
  loadSpec: Fig.LoadSpec,
  initialize: Initializer,
): LoadSpec {
  if (typeof loadSpec === "string") {
    return [{ name: loadSpec, type: SpecLocationSource.GLOBAL }];
  }
  if (typeof loadSpec === "function") {
    return (...args) =>
      loadSpec(...args).then((result) => {
        if (Array.isArray(result)) {
          return result;
        }
        if ("type" in result) {
          return [result];
        }
        return convertSubcommand(result, initialize);
      });
  }
  return convertSubcommand(loadSpec, initialize);
}

const initializeGenerator = (generator: Fig.Generator): Fig.Generator => {
  const templates = generator.template ? makeArray(generator.template) : [];
  const isPath =
    templates.includes("folders") || templates.includes("filepaths");
  return {
    ...generator,
    trigger: isPath ? (generator.trigger ?? "/") : generator.trigger,
    getQueryTerm: isPath
      ? (generator.getQueryTerm ?? "/")
      : generator.getQueryTerm,
  };
};

function initializeOptionMeta(option: Fig.Option): OptionMeta {
  return option;
}

function initializeArgMeta(arg: Fig.Arg): Arg {
  const { template, ...rest } = arg;
  const generators = template
    ? [{ template }]
    : makeArray(arg.generators ?? []);
  return {
    ...rest,
    loadSpec: arg.loadSpec
      ? convertLoadSpec(arg.loadSpec, initializeDefault)
      : undefined,
    generators: generators.map(initializeGenerator),
  };
}

function initializeSubcommandMeta(subcommand: Fig.Subcommand): SubcommandMeta {
  return {
    ...subcommand,
    loadSpec: subcommand.loadSpec
      ? convertLoadSpec(subcommand.loadSpec, initializeDefault)
      : undefined,
  };
}

export const initializeDefault: Initializer = {
  subcommand: initializeSubcommandMeta,
  option: initializeOptionMeta,
  arg: initializeArgMeta,
};
