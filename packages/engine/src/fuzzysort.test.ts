import { expect, test } from "bun:test";
import { single } from "./fuzzysort";

const scoreOf = (search: string, target: string) => {
  const result = single(search, target);
  if (!result) {
    throw new Error(`expected "${search}" to match "${target}"`);
  }
  return result.score;
};

test("exact match scores zero and covers the whole target", () => {
  expect(single("foo", "foo")).toEqual({
    score: 0,
    target: "foo",
    indexes: [0, 1, 2],
  });
});

test("prefix match keeps contiguous indexes at the start", () => {
  const result = single("foo", "foobar");
  expect(result?.indexes).toEqual([0, 1, 2]);
  expect(result?.score).toBeLessThan(0);
});

test("substring match reports the matched target positions", () => {
  expect(single("bar", "foobar")?.indexes).toEqual([3, 4, 5]);
});

test("scattered match reports every matched position", () => {
  expect(single("fbr", "foobar")?.indexes).toEqual([0, 3, 5]);
});

test("no match returns null", () => {
  expect(single("xyz", "foobar")).toBeNull();
  expect(single("oof", "foo")).toBeNull();
  expect(single("foobar", "foo")).toBeNull();
});

test("empty search matches everything with the shape helpers.ts builds", () => {
  expect(single("", "foobar")).toEqual({
    score: 0,
    target: "foobar",
    indexes: [],
  });
});

test("matching case beats mismatched case", () => {
  expect(scoreOf("foo", "foo")).toBeGreaterThan(scoreOf("foo", "Foo"));
  expect(scoreOf("oBa", "FooBar")).toBeGreaterThan(scoreOf("oba", "FooBar"));
});

test("case insensitive matches still match", () => {
  expect(single("OBA", "FooBar")?.indexes).toEqual([2, 3, 4]);
  expect(single("foobar", "FooBar")?.indexes).toEqual([0, 1, 2, 3, 4, 5]);
});

test("word boundary beats word interior", () => {
  expect(scoreOf("bar", "foo-bar")).toBeGreaterThan(scoreOf("bar", "foobar"));
  expect(scoreOf("bar", "fooBar")).toBeGreaterThan(scoreOf("bar", "foobar"));
});

test("shorter target beats longer target for the same match class", () => {
  expect(scoreOf("foo", "foob")).toBeGreaterThan(scoreOf("foo", "foobar"));
});

test("score ordering runs exact, prefix, boundary, interior, scattered", () => {
  const scores = [
    scoreOf("ab", "ab"),
    scoreOf("ab", "abc"),
    scoreOf("ab", "x-ab"),
    scoreOf("ab", "xab"),
    scoreOf("ab", "a-b"),
    scoreOf("ab", "axb"),
  ];
  const sorted = [...scores].sort((a, b) => b - a);
  expect(scores).toEqual(sorted);
  expect(new Set(scores).size).toBe(scores.length);
});

test("only a perfect match scores zero, every other match scores at most -1", () => {
  const targets = ["foo", "Foo", "foobar", "f-o-o", "xxfoo", "fXoXo"];
  for (const target of targets) {
    const score = scoreOf("foo", target);
    expect(score).toBeLessThanOrEqual(target === "foo" ? 0 : -1);
    expect(Number.isInteger(score)).toBe(true);
  }
});

test("prefers the earliest occurrence when several match equally well", () => {
  expect(single("ab", "ab-ab-ab")?.indexes).toEqual([0, 1]);
});

test("prefers a word boundary occurrence over an earlier interior one", () => {
  expect(single("log", "catalog.log")?.indexes).toEqual([8, 9, 10]);
});

test("prefers a later contiguous occurrence over an early scattered one", () => {
  expect(single("abc", "axbxc-abc")?.indexes).toEqual([6, 7, 8]);
});

test("matches unicode targets", () => {
  expect(single("café", "le café")?.indexes).toEqual([3, 4, 5, 6]);
  expect(single("日本", "日本語")?.indexes).toEqual([0, 1]);
  expect(single("🎉", "a🎉b")?.indexes).toEqual([1, 2]);
  expect(single("cafe", "café")).toBeNull();
});

test("handles long targets", () => {
  const long = `${"x".repeat(50_000)}needle${"y".repeat(50_000)}`;
  expect(single("needle", long)?.indexes).toEqual([
    50_000, 50_001, 50_002, 50_003, 50_004, 50_005,
  ]);
  expect(single("zzz", long)).toBeNull();
});
