#!/usr/bin/env node

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

function usage() {
  process.stderr.write(
    "Usage: scripts/local/apply-policy-preset.js <sandbox-name> <preset-file>\n"
  );
}

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: options.stdio || "pipe",
    input: options.input,
  });

  if (result.error) {
    throw result.error;
  }

  return result;
}

function extractPresetEntries(content) {
  const match = content.match(/^network_policies:\n([\s\S]*)$/m);
  if (!match) {
    return null;
  }
  return match[1].trimEnd();
}

function parseCurrentPolicy(raw) {
  if (!raw) {
    return "";
  }

  const separatorIndex = raw.indexOf("---");
  if (separatorIndex === -1) {
    return raw.trim();
  }

  return raw.slice(separatorIndex + 3).trim();
}

function mergePresetEntries(currentPolicy, presetEntries) {
  if (!currentPolicy) {
    return `version: 1\n\nnetwork_policies:\n${presetEntries}\n`;
  }

  if (!currentPolicy.includes("network_policies:")) {
    const withVersion = currentPolicy.includes("version:")
      ? currentPolicy
      : `version: 1\n${currentPolicy}`;
    return `${withVersion.trimEnd()}\n\nnetwork_policies:\n${presetEntries}\n`;
  }

  const lines = currentPolicy.split("\n");
  const merged = [];
  let inNetworkPolicies = false;
  let inserted = false;

  for (const line of lines) {
    const isTopLevelKey = /^\S.*:/.test(line);

    if (line.trim() === "network_policies:" || line.trim().startsWith("network_policies:")) {
      inNetworkPolicies = true;
      merged.push(line);
      continue;
    }

    if (inNetworkPolicies && isTopLevelKey && !inserted) {
      merged.push(presetEntries);
      inserted = true;
      inNetworkPolicies = false;
    }

    merged.push(line);
  }

  if (inNetworkPolicies && !inserted) {
    merged.push(presetEntries);
  }

  return `${merged.join("\n").trimEnd()}\n`;
}

const [, , sandboxName, presetFile] = process.argv;

if (!sandboxName || !presetFile) {
  usage();
  process.exit(1);
}

if (!fs.existsSync(presetFile)) {
  fail(`Preset file does not exist: ${presetFile}`);
}

const presetContent = fs.readFileSync(presetFile, "utf8");
const presetEntries = extractPresetEntries(presetContent);
if (!presetEntries) {
  fail(`Preset file is missing a network_policies section: ${presetFile}`);
}

const currentPolicyResult = run("openshell", ["policy", "get", "--full", sandboxName]);
if (currentPolicyResult.status !== 0) {
  process.stderr.write(currentPolicyResult.stderr || "");
  process.exit(currentPolicyResult.status || 1);
}

const mergedPolicy = mergePresetEntries(
  parseCurrentPolicy(currentPolicyResult.stdout),
  presetEntries
);
const policyFile = path.join(os.tmpdir(), `openclaw-policy-${Date.now()}.yaml`);

fs.writeFileSync(policyFile, mergedPolicy, "utf8");

try {
  const applyResult = run(
    "openshell",
    ["policy", "set", "--policy", policyFile, "--wait", sandboxName],
    { stdio: "inherit" }
  );
  process.exitCode = applyResult.status || 0;
} finally {
  fs.rmSync(policyFile, { force: true });
}
