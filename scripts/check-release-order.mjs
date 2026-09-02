#!/usr/bin/env node

function fail(message) {
  console.error(`error: ${message}`)
  process.exit(2)
}

function parse(version) {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-beta(?:\.([1-9]\d*))?)?$/.exec(version)
  if (!match) fail(`unsupported version: ${version}`)
  const beta = version.includes("-beta")
  return {
    raw: version,
    core: match.slice(1, 4).map(Number),
    beta,
    betaNumber: beta ? (match[4] ? Number(match[4]) : 0) : null,
  }
}

function compare(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left.core[index] !== right.core[index]) return left.core[index] < right.core[index] ? -1 : 1
  }
  if (left.beta !== right.beta) return left.beta ? -1 : 1
  if (!left.beta) return 0
  if (left.betaNumber === right.betaNumber) return 0
  return left.betaNumber < right.betaNumber ? -1 : 1
}

function assertNewer(candidate, existing, label) {
  if (!existing) return
  if (compare(candidate, parse(existing)) <= 0) {
    fail(`${candidate.raw} must be newer than npm ${label} ${existing}`)
  }
}

function check(candidateRaw, channel, latestRaw, betaRaw) {
  const candidate = parse(candidateRaw)
  if (channel !== "stable" && channel !== "beta") fail(`unsupported release channel: ${channel}`)
  if ((channel === "stable") === candidate.beta) fail(`${candidateRaw} does not match ${channel} channel`)
  assertNewer(candidate, latestRaw, "latest")
  if (channel === "beta") assertNewer(candidate, betaRaw, "beta")
}

function expectPass(...args) {
  check(...args)
}

function expectFail(...args) {
  const originalExit = process.exit
  const originalError = console.error
  let failed = false
  process.exit = () => { failed = true; throw new Error("expected failure") }
  console.error = () => {}
  try {
    check(...args)
  } catch (error) {
    if (!failed) throw error
  } finally {
    process.exit = originalExit
    console.error = originalError
  }
  if (!failed) fail(`expected rejection: ${args.join(" ")}`)
}

if (process.argv[2] === "--self-test") {
  expectPass("1.2.1", "stable", "1.2.0", "")
  expectPass("1.2.2-beta", "beta", "1.2.1", "")
  expectPass("1.2.2-beta.2", "beta", "1.2.1", "1.2.2-beta.1")
  expectPass("2.0.0-beta", "beta", "1.9.9", "1.9.10-beta.9")
  expectFail("1.2.1", "stable", "1.2.1", "")
  expectFail("1.2.0", "stable", "1.2.1", "")
  expectFail("1.2.1-beta", "beta", "1.2.1", "")
  expectFail("1.2.2-beta", "beta", "1.2.1", "1.2.2-beta.1")
  expectFail("1.2.2-beta", "stable", "1.2.1", "")
  expectFail("1.2.2", "beta", "1.2.1", "")
  console.log("release order self-test OK")
  process.exit(0)
}

if (process.argv.length !== 6) {
  fail("usage: check-release-order.mjs <version> <stable|beta> <npm-latest-or-empty> <npm-beta-or-empty>")
}
check(process.argv[2], process.argv[3], process.argv[4], process.argv[5])
console.log(`release order OK: ${process.argv[2]} (${process.argv[3]})`)
