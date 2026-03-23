#!/usr/bin/env node

const http = require("http");
const { URL } = require("url");

const relayPort = Number(process.env.LOCAL_OPENAI_RELAY_PORT || "8787");
const upstreamBase = process.env.LOCAL_OPENAI_RELAY_UPSTREAM || "https://api.openai.com";
const defaultApiKey = process.env.OPENAI_API_KEY || "";
const smokeStubModel = process.env.LOCAL_OPENAI_SMOKE_STUB_MODEL || "openclaw-smoke-stub";
const smokeStubText = process.env.LOCAL_OPENAI_SMOKE_STUB_TEXT || "ok";

const hopByHopHeaders = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "host",
  "content-length",
]);

function collectBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function filterHeaders(headers) {
  const out = {};
  for (const [name, value] of Object.entries(headers)) {
    if (value == null) continue;
    if (hopByHopHeaders.has(name.toLowerCase())) continue;
    out[name] = value;
  }
  return out;
}

function isJsonRequest(headers) {
  const contentType = String(headers["content-type"] || headers["Content-Type"] || "");
  return contentType.toLowerCase().includes("application/json");
}

function parseJsonBody(body, headers) {
  if (!body.length || !isJsonRequest(headers)) {
    return null;
  }

  try {
    return JSON.parse(body.toString("utf8"));
  } catch {
    return null;
  }
}

function isChatCompletionsPath(pathname) {
  return pathname === "/v1/chat/completions" || pathname === "/chat/completions";
}

function isResponsesPath(pathname) {
  return pathname === "/v1/responses" || pathname === "/responses";
}

function isModelsPath(pathname) {
  return pathname === "/v1/models" || pathname === "/models";
}

function jsonResponse(res, statusCode, payload, extraHeaders = {}) {
  res.writeHead(statusCode, {
    "content-type": "application/json",
    ...extraHeaders,
  });
  res.end(JSON.stringify(payload));
}

function eventStreamHeaders() {
  return {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
  };
}

function writeSse(res, data, eventName) {
  if (eventName) {
    res.write(`event: ${eventName}\n`);
  }
  res.write(`data: ${JSON.stringify(data)}\n\n`);
}

function writeSseDone(res) {
  res.write("data: [DONE]\n\n");
  res.end();
}

function buildChatCompletion(model) {
  const created = Math.floor(Date.now() / 1000);
  return {
    id: `chatcmpl_stub_${created}`,
    object: "chat.completion",
    created,
    model,
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content: smokeStubText,
        },
        finish_reason: "stop",
      },
    ],
    usage: {
      prompt_tokens: 1,
      completion_tokens: 1,
      total_tokens: 2,
    },
  };
}

function writeChatCompletionStream(res, model) {
  const created = Math.floor(Date.now() / 1000);
  const id = `chatcmpl_stub_${created}`;

  res.writeHead(200, eventStreamHeaders());
  writeSse(res, {
    id,
    object: "chat.completion.chunk",
    created,
    model,
    choices: [
      {
        index: 0,
        delta: {
          role: "assistant",
          content: smokeStubText,
        },
        finish_reason: null,
      },
    ],
  });
  writeSse(res, {
    id,
    object: "chat.completion.chunk",
    created,
    model,
    choices: [
      {
        index: 0,
        delta: {},
        finish_reason: "stop",
      },
    ],
  });
  writeSseDone(res);
}

function buildResponsesPayload(model) {
  const createdAt = Math.floor(Date.now() / 1000);
  return {
    id: `resp_stub_${createdAt}`,
    object: "response",
    created_at: createdAt,
    status: "completed",
    model,
    output: [
      {
        id: `msg_stub_${createdAt}`,
        type: "message",
        role: "assistant",
        content: [
          {
            type: "output_text",
            text: smokeStubText,
            annotations: [],
          },
        ],
      },
    ],
    usage: {
      input_tokens: 1,
      output_tokens: 1,
      total_tokens: 2,
    },
  };
}

function writeResponsesStream(res, model) {
  const payload = buildResponsesPayload(model);
  const message = payload.output[0];
  const content = message.content[0];

  res.writeHead(200, eventStreamHeaders());
  writeSse(res, payload, "response.created");
  writeSse(
    res,
    {
      response_id: payload.id,
      item_id: message.id,
      output_index: 0,
      content_index: 0,
      delta: content.text,
    },
    "response.output_text.delta"
  );
  writeSse(
    res,
    {
      response_id: payload.id,
      item_id: message.id,
      output_index: 0,
      content_index: 0,
      text: content.text,
    },
    "response.output_text.done"
  );
  writeSse(res, payload, "response.completed");
  res.end();
}

function buildStubModelList() {
  return {
    object: "list",
    data: [
      {
        id: smokeStubModel,
        object: "model",
        created: Math.floor(Date.now() / 1000),
        owned_by: "openclaw-local",
      },
    ],
  };
}

function appendStubModel(payload) {
  if (!payload || payload.object !== "list" || !Array.isArray(payload.data)) {
    return payload;
  }

  if (payload.data.some((entry) => entry && entry.id === smokeStubModel)) {
    return payload;
  }

  return {
    ...payload,
    data: [...payload.data, buildStubModelList().data[0]],
  };
}

async function proxyUpstream(req, body, upstreamUrl, headers) {
  return fetch(upstreamUrl, {
    method: req.method,
    headers,
    body: body.length > 0 ? body : undefined,
    duplex: body.length > 0 ? "half" : undefined,
  });
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.url === "/healthz") {
      jsonResponse(res, 200, {
        ok: true,
        upstreamBase,
        smokeStubModel,
        relayVersion: 2,
      });
      return;
    }

    const upstreamUrl = new URL(req.url || "/", upstreamBase);
    const body = await collectBody(req);
    const headers = filterHeaders(req.headers);
    const parsedBody = parseJsonBody(body, req.headers);
    const stubRequested = parsedBody && parsedBody.model === smokeStubModel;

    if (!headers.authorization && defaultApiKey) {
      headers.authorization = `Bearer ${defaultApiKey}`;
    }

    if (stubRequested && req.method === "POST" && isChatCompletionsPath(upstreamUrl.pathname)) {
      process.stdout.write(`stubbed ${req.method} ${upstreamUrl.pathname} model=${smokeStubModel}\n`);
      if (parsedBody.stream === true) {
        writeChatCompletionStream(res, smokeStubModel);
        return;
      }
      jsonResponse(res, 200, buildChatCompletion(smokeStubModel));
      return;
    }

    if (stubRequested && req.method === "POST" && isResponsesPath(upstreamUrl.pathname)) {
      process.stdout.write(`stubbed ${req.method} ${upstreamUrl.pathname} model=${smokeStubModel}\n`);
      if (parsedBody.stream === true) {
        writeResponsesStream(res, smokeStubModel);
        return;
      }
      jsonResponse(res, 200, buildResponsesPayload(smokeStubModel));
      return;
    }

    const upstreamResponse = await proxyUpstream(req, body, upstreamUrl, headers);

    if (req.method === "GET" && isModelsPath(upstreamUrl.pathname)) {
      const responseHeaders = filterHeaders(Object.fromEntries(upstreamResponse.headers.entries()));
      const text = await upstreamResponse.text();
      try {
        const payload = appendStubModel(JSON.parse(text));
        jsonResponse(res, upstreamResponse.status, payload, responseHeaders);
      } catch {
        res.writeHead(upstreamResponse.status, responseHeaders);
        res.end(text);
      }
      return;
    }

    const responseHeaders = filterHeaders(Object.fromEntries(upstreamResponse.headers.entries()));
    res.writeHead(upstreamResponse.status, responseHeaders);
    const upstreamBody = Buffer.from(await upstreamResponse.arrayBuffer());
    res.end(upstreamBody);
  } catch (error) {
    process.stderr.write(`relay error: ${error instanceof Error ? error.stack || error.message : String(error)}\n`);
    res.writeHead(502, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        error: "relay_request_failed",
        message: error instanceof Error ? error.message : String(error),
      })
    );
  }
});

server.listen(relayPort, "0.0.0.0", () => {
  process.stdout.write(`openai relay listening on 0.0.0.0:${relayPort}\n`);
});
