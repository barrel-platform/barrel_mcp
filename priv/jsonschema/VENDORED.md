# JSON Schema 2020-12 metaschema

The dialect's own schema documents, vendored so that validating a
schema never becomes a network request. `barrel_mcp_jsonschema`
registers each under the `$id` it declares.

Fetched from https://json-schema.org/draft/2020-12/ on 2026-08-26.
These documents are stable: the draft is published and the URIs are
the dialect's identity, so a change would be a new dialect.

## Contents

| file | sha256 |
|---|---|
| `meta_applicator.json` | `bf273b26f9f735b93ece78f2b61b36676e1d122ce78ab37ad5a2e45dfa1ca2b1` |
| `meta_content.json` | `a10456605b2b5bb12a1b4dcfc0300f02f54d3e8bb3646bed7724583866627682` |
| `meta_core.json` | `21f79d143fab1f180245c331e5657057045b36794d41fe151e6e4fed65035299` |
| `meta_format-annotation.json` | `5c79404f831dd905c0f40fefac7c6f3e51bf3729b4a876a5c2020178d97f3bcc` |
| `meta_meta-data.json` | `c664d438a84d58889c8edecd248ce2f945a4bc0e3b087323b11303dc136abfbe` |
| `meta_unevaluated.json` | `fc99f32188da41689a9382af174dd42e8b255e4374965c157b8286556b4ab2bc` |
| `meta_validation.json` | `e921c5b79264d3689af01c1af1ffdf692e09f1c45df90a0f08eb7288c9acdeab` |
| `schema.json` | `41da76f5afb7ce062d248f762463a92f7ca47e4e0f905b224ba6afeef91ded0f` |

## Dialects

A schema declaring a `$schema` other than 2020-12 is refused, unless the
caller supplied that metaschema: a custom one built on these
vocabularies is still this dialect. A `$ref` that lands in a document of
another draft is still evaluated under 2020-12, which is the cross-draft
case the suite keeps in `optional/` and we do not claim.

## Updating

There is no reason to, short of a new dialect. If you do, re-fetch
each URI, replace the hashes above, and run
`rebar3 ct --suite=test/barrel_mcp_json_schema_SUITE`: the official
suite exercises these documents through the `$ref`s that reach them.
