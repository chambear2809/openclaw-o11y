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

function normalizeYaml(content) {
  return String(content || "").replace(/\r\n/g, "\n");
}

function extractPresetEntries(content) {
  const section = extractNetworkPoliciesSection(content);
  if (!section) {
    return null;
  }
  return section.split("\n").slice(1).join("\n").trimEnd();
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

function extractNetworkPoliciesSection(content) {
  const lines = normalizeYaml(content).split("\n");
  const section = [];
  let inNetworkPolicies = false;

  for (const line of lines) {
    if (!inNetworkPolicies) {
      if (line.trim() === "network_policies:") {
        inNetworkPolicies = true;
        section.push("network_policies:");
      }
      continue;
    }

    if (/^[^\s#][^:]*:/.test(line)) {
      break;
    }

    section.push(line);
  }

  if (!inNetworkPolicies) {
    return null;
  }

  return section.join("\n").trimEnd();
}

function extractPolicyBlocks(entries) {
  const lines = normalizeYaml(entries).split("\n");
  const blocks = [];
  let currentBlock = null;

  for (const line of lines) {
    const blockStart = line.match(/^ {2}([^:\s][^:]*):(?:\s+.*)?$/);
    if (blockStart) {
      if (currentBlock) {
        blocks.push({
          name: currentBlock.name,
          content: currentBlock.lines.join("\n").trimEnd(),
        });
      }
      currentBlock = {
        name: blockStart[1],
        lines: [line],
      };
      continue;
    }

    if (currentBlock) {
      currentBlock.lines.push(line);
    }
  }

  if (currentBlock) {
    blocks.push({
      name: currentBlock.name,
      content: currentBlock.lines.join("\n").trimEnd(),
    });
  }

  return blocks;
}

function splitPolicyAroundNetworkPolicies(content) {
  const lines = normalizeYaml(content).trim().split("\n");
  const before = [];
  const network = [];
  const after = [];
  let state = "before";
  let hasNetworkPolicies = false;

  for (const line of lines) {
    if (state === "before") {
      if (line.trim() === "network_policies:") {
        hasNetworkPolicies = true;
        state = "network";
        continue;
      }
      before.push(line);
      continue;
    }

    if (state === "network" && /^[^\s#][^:]*:/.test(line)) {
      state = "after";
    }

    if (state === "network") {
      network.push(line);
    } else {
      after.push(line);
    }
  }

  return {
    before: before.join("\n").trimEnd(),
    networkEntries: network.join("\n").trimEnd(),
    after: after.join("\n").trimEnd(),
    hasNetworkPolicies,
  };
}

function renderNetworkPolicies(blocks) {
  const renderedBlocks = blocks
    .map((block) => block.content.trimEnd())
    .filter(Boolean)
    .join("\n");

  if (!renderedBlocks) {
    return "network_policies:";
  }

  return `network_policies:\n${renderedBlocks}`;
}

function mergePresetEntries(currentPolicy, presetEntries) {
  const presetBlocks = extractPolicyBlocks(presetEntries);
  if (presetBlocks.length === 0) {
    return `${normalizeYaml(currentPolicy).trimEnd()}\n`;
  }

  const normalizedCurrent = normalizeYaml(currentPolicy).trim();
  const currentWithVersion = normalizedCurrent
    ? (/(?:^|\n)version:/.test(normalizedCurrent)
        ? normalizedCurrent
        : `version: 1\n${normalizedCurrent}`)
    : "version: 1";
  const sections = splitPolicyAroundNetworkPolicies(currentWithVersion);
  const existingBlocks = sections.hasNetworkPolicies
    ? extractPolicyBlocks(sections.networkEntries)
    : [];
  const presetNames = new Set(presetBlocks.map((block) => block.name));
  const mergedBlocks = existingBlocks
    .filter((block) => !presetNames.has(block.name))
    .concat(presetBlocks);
  const merged = [];

  if (sections.before) {
    merged.push(sections.before);
  }
  merged.push(renderNetworkPolicies(mergedBlocks));
  if (sections.after) {
    merged.push(sections.after);
  }

  return `${merged.join("\n\n").trimEnd()}\n`;
}

function main() {
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
}

module.exports = {
  extractPresetEntries,
  mergePresetEntries,
  parseCurrentPolicy,
};

if (require.main === module) {
  main();
}
