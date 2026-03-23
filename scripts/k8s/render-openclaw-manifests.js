#!/usr/bin/env node

const fs = require("fs");

const input = fs.readFileSync(0, "utf8");

function required(name, fallback) {
  const value = process.env[name] ?? fallback;
  if (value == null || value === "") {
    throw new Error(`Missing required render variable: ${name}`);
  }
  return value;
}

function yamlString(value) {
  return JSON.stringify(value);
}

function renderAnnotations(instrumentationRef) {
  if (!instrumentationRef) {
    return "";
  }

  return [
    "      annotations:",
    `        instrumentation.opentelemetry.io/inject-nodejs: ${yamlString(instrumentationRef)}`,
    '        instrumentation.opentelemetry.io/container-names: "openclaw"',
  ].join("\n");
}

const replacements = new Map([
  ["__OPENCLAW_STORAGE_CLASS__", yamlString(required("OPENCLAW_STORAGE_CLASS"))],
  ["__OPENCLAW_IMAGE__", yamlString(required("OPENCLAW_IMAGE"))],
  ["__OPENCLAW_NODE_OPTIONS__", yamlString(required("OPENCLAW_NODE_OPTIONS"))],
  ["__OPENCLAW_SERVICE_NAME__", yamlString(required("OPENCLAW_SERVICE_NAME"))],
  ["__OPENCLAW_RESOURCE_ATTRIBUTES__", yamlString(required("OPENCLAW_RESOURCE_ATTRIBUTES"))],
  ["__OPENCLAW_SECRET_NAME__", yamlString(required("OPENCLAW_SECRET_NAME"))],
  ["__OPENCLAW_MEMORY_REQUEST__", yamlString(required("OPENCLAW_MEMORY_REQUEST"))],
  ["__OPENCLAW_MEMORY_LIMIT__", yamlString(required("OPENCLAW_MEMORY_LIMIT"))],
]);

let output = input;
for (const [placeholder, value] of replacements.entries()) {
  output = output.replaceAll(placeholder, value);
}

const renderedAnnotations = renderAnnotations(process.env.OPENCLAW_INSTRUMENTATION_REF || "");
output = output.replace(
  /      annotations:\n        __OPENCLAW_POD_TEMPLATE_ANNOTATIONS__: "?__OPENCLAW_POD_TEMPLATE_ANNOTATIONS_VALUE__"?\n/g,
  renderedAnnotations ? `${renderedAnnotations}\n` : ""
);

process.stdout.write(output);
