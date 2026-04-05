# KurrentDB Projection Generator — Design Spec

**Date:** 2026-04-05  
**Status:** Approved

## Problem

When a new ReadModel is defined in `projection-model.yaml`, a corresponding KurrentDB server-side projection (JS) must also exist to route events into the per-entity derived stream that the Swift projector reads from. Currently these JS files are hand-written separately, creating a gap between the YAML definition and the deployed projection.

## Goal

Extend the generator so that `projection-model.yaml` can also describe KurrentDB routing projections, and a new **Command Plugin** generates the corresponding `.js` files into `projections/`.

## YAML Schema Extension

Two new optional top-level fields per ReadModel definition:

| Field | Type | Description |
|-------|------|-------------|
| `category` | String | KurrentDB aggregate category. Generates `fromStreams(["$ce-{category}"])`. Required for JS generation. |
| `idField` | String | Default field in `event.body` used as the ReadModel routing key. Used when an event entry is a plain string. Optional if all events have custom handlers. |

### Event list format

`events` (and `createdEvents`) remain a YAML list, but each item can be:

- **Plain string** — uses `idField` to generate the standard `linkTo`:
  ```yaml
  events:
    - EventA
  ```

- **Mapping with `|` body** — the value is raw JS placed inside the standard `function(state, event)` wrapper:
  ```yaml
  events:
    - EventB: |
        linkTo("OtherTarget-" + event.body.otherId, event);
  ```

### Full example

```yaml
OC_GetQuotationIdByQuotingCaseId:
  model: readModel
  category: Quotation
  idField: quotingCaseId
  createdEvents:
    - QuotationCreated
  events:
    - QuotationUpdated
    - QuotationReassigned: |
        linkTo("OC_GetQuotationIdByQuotingCaseId-" + event.body.newCaseId, event);
```

### Generated JS

```js
fromStreams(["$ce-Quotation"])
.when({
    $init: function(){ return {} },
    QuotationCreated: function(state, event) {
        if (event.isJson) {
            linkTo("OC_GetQuotationIdByQuotingCaseId-" + event.body["quotingCaseId"], event);
        }
    },
    QuotationUpdated: function(state, event) {
        if (event.isJson) {
            linkTo("OC_GetQuotationIdByQuotingCaseId-" + event.body["quotingCaseId"], event);
        }
    },
    QuotationReassigned: function(state, event) {
        if (event.isJson) {
            linkTo("OC_GetQuotationIdByQuotingCaseId-" + event.body.newCaseId, event);
        }
    }
});
```

## Three-Tier Design

| Tier | YAML | Output |
|------|------|--------|
| Standard routing | `category` + `idField` + plain string events | Fully generated JS |
| Custom handler | Event entry with `\|` body | Boilerplate generated, custom body embedded |
| Full custom | No YAML — hand-written `.js` | Not touched by generator |

Tiers 1 and 2 can be mixed within a single definition. Tier 3 coexists in `projections/` without conflict.

## Components

### 1. `EventProjectionDefinition` (DomainEventGenerator)

Add two new optional decoded fields:
- `category: String?`
- `idField: String?`

Update event item decoding to support the mixed list format (string OR `{name: body}` mapping).

### 2. `KurrentDBProjectionGenerator` (DomainEventGenerator)

New generator struct. Given an `EventProjectionDefinition`, renders the JS string:

```
fromStreams(["$ce-{category}"])
.when({
    $init: function(){ return {} },
    {for each event}
    {EventName}: function(state, event) {
        if (event.isJson) {
            {body}   // either generated linkTo or custom | body
        }
    },
})
```

Only runs when `category` is present. Definitions without `category` are skipped (existing behaviour unchanged).

### 3. `generate kurrentdb-projection` subcommand (generate executable)

New subcommand added to `Sources/generate/`. Accepts:
- `--input <projection-model.yaml>`
- `--output <directory>` (default: `projections/`)
- `--config <event-generator-config.yaml>` (optional, for access modifiers)

Iterates definitions, runs `KurrentDBProjectionGenerator` for each that has `category`, writes `{ModelName}Projection.js`.

### 4. `GenerateKurrentDBProjectionsPlugin` (Command Plugin)

New SPM Command Plugin. Locates `projection-model.yaml` in the target, invokes `generate kurrentdb-projection`. User runs:

```bash
swift package generate-kurrentdb-projections
```

## Error Handling

| Condition | Behaviour |
|-----------|-----------|
| `category` present but `idField` absent and a plain-string event exists | Emit error: plain-string event requires `idField` |
| `|` body is empty string | Emit error: custom handler body cannot be empty |
| Output directory does not exist | Create it |
| Existing `.js` file for same name | Overwrite (idempotent) |

## Testing Strategy (TDD)

All new logic is tested before implementation.

**Unit tests (`DomainEventGeneratorTests`):**
- YAML parsing: plain-string events decoded correctly
- YAML parsing: mapping events (`EventName: |`) decoded correctly
- YAML parsing: mixed list decoded correctly
- Generator: standard routing produces correct `fromStreams` + `linkTo`
- Generator: custom handler body is embedded verbatim inside wrapper
- Generator: definition without `category` produces no output
- Generator: missing `idField` with plain-string event throws error

**Integration tests (`GenerateKurrentDBProjectionsCLITests`):**
- CLI subcommand writes correct `.js` file to output directory
- Existing file is overwritten on re-run
- Multiple definitions in one YAML produce multiple files

## Out of Scope

- Generating the Swift projector protocol (already handled by existing `generate projection`)
- Managing KurrentDB deployment (handled by existing `projection.sh`)
- Validating JS syntax of `|` bodies
- Supporting `fromAll()` or multi-stream `fromStreams([...])` patterns
