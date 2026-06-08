// Test case: string literal as object key
const obj = {
  "resolution-mode": "bundler"
};

// Test case: string literal in other contexts
const str: "hello" = "hello";
const tuple = ["c", "d"];
let mutable_str = "test";

// Test case: string literal NOT as a property key
const arr = ["key", "value"];
type MyType = "option1" | "option2";
