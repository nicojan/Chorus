import { normalizeAddress } from "../src/index.js";

const cases = [
  // [input, expected, why]
  ["203.0.113.10", "203.0.113.10", "IPv4 passes through"],
  ["", "", "empty stays empty"],
  [null, "", "missing header stays empty"],
  // Same /64, different host halves: privacy extensions rotating.
  ["2606:4700:3037:0:1111:2222:3333:4444", "2606:4700:3037:0::/64", "full form keeps 4 groups"],
  ["2606:4700:3037:0:aaaa:bbbb:cccc:dddd", "2606:4700:3037:0::/64", "rotated host half collapses to same prefix"],
  ["2606:4700:3037::6815:4fda", "2606:4700:3037:0::/64", "compressed form expands to the same prefix"],
  // A different /64 must NOT collapse into the one above.
  ["2606:4700:3038::6815:4fda", "2606:4700:3038:0::/64", "different network stays distinct"],
  ["::1", "0:0:0:0::/64", "loopback"],
  ["2606:4700:3037:1:2:3:4:5%en0", "2606:4700:3037:1::/64", "zone index stripped"],
  ["2606:4700:3037:ABCD::1", "2606:4700:3037:abcd::/64", "case normalized"],
];

let failed = 0;
for (const [input, expected, why] of cases) {
  const got = normalizeAddress(input);
  const ok = got === expected;
  if (!ok) failed += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${why}\n      ${JSON.stringify(input)} -> ${JSON.stringify(got)}${ok ? "" : ` (expected ${JSON.stringify(expected)})`}`);
}

// The property that actually matters: two rotated addresses on one network
// must produce one marker, and two networks must produce two.
const rotated = new Set(["2606:4700:3037::1", "2606:4700:3037::beef", "2606:4700:3037:0:9:9:9:9"].map(normalizeAddress));
const networks = new Set(["2606:4700:3037::1", "2606:4700:9999::1"].map(normalizeAddress));
console.log(`\n${rotated.size === 1 ? "PASS" : "FAIL"}  three rotated addresses on one /64 -> ${rotated.size} marker(s), want 1`);
console.log(`${networks.size === 2 ? "PASS" : "FAIL"}  two different /64s -> ${networks.size} marker(s), want 2`);
if (rotated.size !== 1 || networks.size !== 2) failed += 1;

console.log(failed === 0 ? "\nAll address cases pass." : `\n${failed} FAILING`);
process.exit(failed === 0 ? 0 : 1);
