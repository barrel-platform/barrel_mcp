// Stopgap for the pinned @modelcontextprotocol/conformance bundle until
// the upstream fix lands: its wire-schema check validates every
// `tools/call` answer against the core CallToolResult, and at
// 2026-07-28 the core schema no longer carries CreateTaskResult
// (SEP-2663 moved it into the tasks extension), so a task handle can
// never pass. The upstream patch validates a `resultType: "task"`
// result against the extension's own schema; this applies the same
// rule to the pinned bundle, compiling the vendored copy of that
// schema (test/schema_vectors/ext-tasks/schema.json) with the ajv the
// runner already depends on.
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

const schemaPath = path.join(
  __dirname,
  '..',
  'schema_vectors',
  'ext-tasks',
  'schema.json'
);
const extTasksSchema = fs.readFileSync(schemaPath, 'utf8');

const helper = `${marker}
let __barrelTaskValidator;
function __barrelTaskResultErrors(result, method) {
  if (__barrelTaskValidator === undefined) {
    const Ajv2020 = require('ajv/dist/2020');
    const addFormats = require('ajv-formats');
    const ajv = new Ajv2020({ strict: false, allErrors: true });
    addFormats(ajv);
    ajv.addFormat('byte', true);
    ajv.addSchema(${extTasksSchema}, 'barrel-ext-tasks');
    __barrelTaskValidator = ajv.compile({
      $ref: 'barrel-ext-tasks#/$defs/CreateTaskResult'
    });
  }
  if (__barrelTaskValidator(result)) return [];
  return (__barrelTaskValidator.errors || []).map(
    (e) =>
      "CreateTaskResult" + (e.instancePath || "") + ": " + e.message +
      " (result of '" + method + "', tasks extension)"
  );
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
