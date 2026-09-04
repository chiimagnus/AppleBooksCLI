import { readFile, rename, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";

const skillNames = ["applebookscli", "applebookscli-zh"];
const source = "chiimagnus/AppleBooksCLI";
const sourceURL = "https://github.com/chiimagnus/AppleBooksCLI.git";
const skillsVersion = "1.5.23";

async function runUpdater(names) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "npx",
      ["-y", `skills@${skillsVersion}`, "update", ...names, "-g", "-y"],
      {
        stdio: "ignore",
        env: { ...process.env, DISABLE_TELEMETRY: "1" },
      },
    );
    child.once("error", reject);
    child.once("exit", resolve);
  });
}

async function main() {
  const packageJSON = JSON.parse(
    await readFile(new URL("../../package.json", import.meta.url), "utf8"),
  );
  // ponytail: skills@1.5.23 还没有公开的“只重绑 ref”命令；只改它自己的 source ref，target 更新仍完全交给官方 updater。
  const lockPath = process.env.XDG_STATE_HOME
    ? join(process.env.XDG_STATE_HOME, "skills", ".skill-lock.json")
    : join(homedir(), ".agents", ".skill-lock.json");

  let rawLock;
  try {
    rawLock = await readFile(lockPath, "utf8");
  } catch {
    return;
  }

  const lock = JSON.parse(rawLock);
  const managed = skillNames.filter((name) => {
    const entry = lock.skills?.[name];
    return entry?.sourceType === "github" &&
      (entry.source === source || entry.sourceUrl === sourceURL);
  });
  if (managed.length === 0) return;

  const targetRef = `v${packageJSON.version}`;
  const changed = managed.some((name) => lock.skills[name].ref !== targetRef);
  if (changed) {
    const mode = (await stat(lockPath)).mode & 0o777;
    const temporary = `${lockPath}.${process.pid}.tmp`;
    for (const name of managed) lock.skills[name].ref = targetRef;
    await writeFile(temporary, `${JSON.stringify(lock, null, 2)}\n`, { mode });
    await rename(temporary, lockPath);
  }

  const code = await runUpdater(managed);
  if (code !== 0) {
    console.warn(
      `applebookscli: Skill update to ${targetRef} did not complete; Agent Skills CLI can retry later.`,
    );
  }
}

try {
  await main();
} catch (error) {
  console.warn(
    `applebookscli: optional Skill update skipped: ${error instanceof Error ? error.message : String(error)}`,
  );
}
