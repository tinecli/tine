import { describe, expect, it } from "bun:test";
import {
  compareNamedObjectsAlphabetically,
  longestCommonPrefix,
  makeArray,
  makeArrayIfExists,
} from "../utils";

describe("makeArray", () => {
  it("should transform an object into an array", () => {
    expect(makeArray(true)).toEqual([true]);
  });

  it("should not transform arrays with one value", () => {
    expect(makeArray([true])).toEqual([true]);
  });

  it("should not transform arrays with multiple values", () => {
    expect(makeArray([true, false])).toEqual([true, false]);
  });
});

describe("makeArrayIfExists", () => {
  it("works", () => {
    expect(makeArrayIfExists(null)).toEqual(null);
    expect(makeArrayIfExists(undefined)).toEqual(null);
    expect(makeArrayIfExists("a")).toEqual(["a"]);
    expect(makeArrayIfExists(["a"])).toEqual(["a"]);
  });
});

describe("longestCommonPrefix", () => {
  it("should return the shared match", () => {
    expect(longestCommonPrefix(["foo", "foo bar", "foo hello world"])).toEqual(
      "foo",
    );
  });

  it("should return nothing if not all items starts by the same chars", () => {
    expect(longestCommonPrefix(["foo", "foo bar", "hello world"])).toEqual("");
  });
});

describe("compareNamedObjectsAlphabetically", () => {
  it("should return 1 to sort alphabetically z against b for string", () => {
    expect(compareNamedObjectsAlphabetically("z", "b")).toBeGreaterThan(0);
  });

  it("should return 1 to sort alphabetically z against b for object with name", () => {
    expect(
      compareNamedObjectsAlphabetically({ name: "z" }, { name: "b" }),
    ).toBeGreaterThan(0);
  });

  it("should return 1 to sort alphabetically c against x for object with name", () => {
    expect(
      compareNamedObjectsAlphabetically({ name: "c" }, { name: "x" }),
    ).toBeLessThan(0);
  });

  it("should return 1 to sort alphabetically z against b for object with name array", () => {
    expect(
      compareNamedObjectsAlphabetically({ name: ["z"] }, { name: ["b"] }),
    ).toBeGreaterThan(0);
  });

  it("should return 1 to sort alphabetically c against x for object with name array", () => {
    expect(
      compareNamedObjectsAlphabetically({ name: ["c"] }, { name: ["x"] }),
    ).toBeLessThan(0);
  });
});
