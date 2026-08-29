// Stopgap for the pinned @modelcontextprotocol/conformance bundle until
// the upstream fix lands: its wire-schema check validates every
// `tools/call` answer against the core CallToolResult, and at
// 2026-07-28 the core schema no longer carries CreateTaskResult
// (SEP-2663 moved it into the tasks extension), so a task handle can
// never pass. The upstream patch validates a `resultType: "task"`
// result against the extension's own schema; this applies the same
// rule to the pinned bundle with the extension's CreateTaskResult
// requirements written out (ext-tasks schema/draft/schema.json).
//
// Idempotent. Refuses to run when the anchor is not found, which is
// what an upstream release changing the validator looks like: then
// either the fix landed and this file goes, or the anchor moved.
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const bundle = path.join(
  __dirname,
  'node_modules',
  '@modelcontextprotocol',
  'conformance',
  'dist',
  'index.js'
);
const marker = '/* barrel_mcp: CreateTaskResult validated via the tasks extension */';

const anchor =
  'if(o.result!==void 0){let e=o.result?.resultType===`input_required`&&`InputRequiredResult`in r.defs?`InputRequiredResult`:n===void 0?void 0:r.resultDefs.get(n);';

const replacement =
  'if(o.result!==void 0){if(o.result?.resultType===`task`&&!(`CreateTaskResult`in r.defs)){let bmErrs=__barrelTaskResultErrors(o.result,n);if(bmErrs.length>0)return bmErrs;return i(a(`JSONRPCResultResponse`,`JSONRPCResponse`),t)}let e=o.result?.resultType===`input_required`&&`InputRequiredResult`in r.defs?`InputRequiredResult`:n===void 0?void 0:r.resultDefs.get(n);';

const helper = `${marker}
function __barrelTaskResultErrors(result, method) {
  const errs = [];
  const tag = (m) => errs.push(m + " (result of '" + method + "', tasks extension)");
  if (typeof result.taskId !== 'string') tag("CreateTaskResult: must have required property 'taskId'");
  const statuses = ['working', 'input_required', 'completed', 'failed', 'cancelled'];
  if (!statuses.includes(result.status)) tag("CreateTaskResult/status: must be one of " + statuses.join(', '));
  for (const k of ['createdAt', 'lastUpdatedAt']) {
    if (typeof result[k] !== 'string') tag("CreateTaskResult: must have required property '" + k + "'");
  }
  if (!('ttlMs' in result)) tag("CreateTaskResult: must have required property 'ttlMs'");
  else if (result.ttlMs !== null && !Number.isInteger(result.ttlMs)) tag('CreateTaskResult/ttlMs: must be integer or null');
  if ('pollIntervalMs' in result && !Number.isInteger(result.pollIntervalMs)) tag('CreateTaskResult/pollIntervalMs: must be integer');
  if ('statusMessage' in result && typeof result.statusMessage !== 'string') tag('CreateTaskResult/statusMessage: must be string');
  return errs;
}
`;

const source = fs.readFileSync(bundle, 'utf8');
if (source.includes(marker)) {
  console.log('conformance runner already patched');
  process.exit(0);
}
if (!source.includes(anchor)) {
  console.error(
    'patch-runner: anchor not found in ' +
      bundle +
      '. The pinned runner changed its validator; drop this patch if the upstream fix landed, else update the anchor.'
  );
  process.exit(1);
}
// The bundle opens with a shebang line, which has to stay first.
const firstBreak = source.indexOf('\n');
const opening = source.startsWith('#!') ? source.slice(0, firstBreak + 1) : '';
const rest = source.slice(opening.length);
const patched = opening + helper + rest.replace(anchor, replacement);
fs.writeFileSync(bundle, patched);
console.log('conformance runner patched: CreateTaskResult validated via the tasks extension');
