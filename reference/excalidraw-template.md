# Excalidraw Element Template & Rendering Rules

## Element template (copy and adapt for `create_view`)

```json
[
  { "type": "cameraUpdate", "x": 0, "y": 0, "zoom": 1, "width": 800, "height": 600 },
  { "type": "rectangle", "id": "r1", "x": 80,  "y": 120, "width": 220, "height": 60,
    "backgroundColor": "#a5d8ff", "fillStyle": "solid", "strokeColor": "#4a9eed",
    "strokeWidth": 2, "roughness": 1, "opacity": 100, "roundness": { "type": 3 },
    "label": { "text": "Entry / Props", "fontSize": 18, "fontFamily": 5 } },
  { "type": "rectangle", "id": "r2", "x": 380, "y": 120, "width": 220, "height": 60,
    "backgroundColor": "#d0bfff", "fillStyle": "solid", "strokeColor": "#845ef7",
    "strokeWidth": 2, "roughness": 1, "opacity": 100, "roundness": { "type": 3 },
    "label": { "text": "Component Logic", "fontSize": 18, "fontFamily": 5 } },
  { "type": "arrow", "id": "a1", "x": 300, "y": 150, "width": 80, "height": 0,
    "strokeColor": "#495057", "strokeWidth": 2, "roughness": 1, "opacity": 100,
    "startBinding": { "elementId": "r1", "gap": 1, "focus": 0 },
    "endBinding":   { "elementId": "r2", "gap": 1, "focus": 0 } }
]
```

Replace labels with real names from code. Add more `rectangle` + `arrow` pairs as needed.

## Color palette

| Color | Hex | Use for |
|-------|-----|---------|
| Blue | `#a5d8ff` | Entry / props / input |
| Purple | `#d0bfff` | Logic / hooks / processing |
| Green | `#b2f2bb` | Output / success |
| Orange | `#ffd8a8` | External / pending |

## Rendering rules

- Always start the elements array with a `cameraUpdate` (4:3 ratio: 800×600 standard, 1200×900 large)
- Use background zone rectangles (low opacity) to group layers: frontend, logic, data
- Use `label` on shapes — never separate text elements for node names in `create_view`
- For sequence diagrams: draw actor headers first → dashed lifeline arrows → message arrows top to bottom
- Decision points use diamond shapes; external systems use rectangles with orange fill
- **All text-bearing elements MUST use `"fontFamily": 5`** — any other value makes text invisible
- Node widths: single word = 140px min, short phrase (2–4 words) = 220px, full sentence = 320px

## CRITICAL — Two separate rendering contexts

**Context A: MCP `create_view` tool** (live rendering in chat)
- Use `"label": { "text": "...", "fontSize": 20 }` directly on shapes

**Context B: Static `.excalidraw` files saved to disk** (VS Code / excalidraw.com)
- NEVER put `"text"` directly on a shape — it is silently ignored
- Every labeled box needs TWO linked elements:
  1. Container shape with `"boundElements": [{ "id": "txt_id", "type": "text" }]`
  2. Text element with `"containerId": "shape_id"`, `"fontFamily": 5`, `"textAlign": "center"`, `"verticalAlign": "middle"`

```json
{ "type": "rectangle", "id": "r1", "x": 100, "y": 100, "width": 300, "height": 70,
  "backgroundColor": "#a5d8ff", "fillStyle": "solid", "strokeColor": "#4a9eed",
  "strokeWidth": 2, "roughness": 1, "opacity": 100, "roundness": { "type": 3 },
  "boundElements": [{ "id": "r1_t", "type": "text" }] },
{ "type": "text", "id": "r1_t", "x": 100, "y": 119, "width": 300, "height": 26,
  "text": "My Label", "fontSize": 21, "fontFamily": 5,
  "textAlign": "center", "verticalAlign": "middle",
  "containerId": "r1", "originalText": "My Label",
  "strokeColor": "#1e1e1e", "roughness": 1, "opacity": 100 }
```

Text element `y` ≈ `shape.y + (shape.height − fontSize × 1.25) / 2`

## Pre-save validation checklist

- [ ] Zero shapes have `"text"` as a direct property
- [ ] Every visible box has a corresponding bound text element with `containerId`
- [ ] Every text element has `"fontFamily": 5`
- [ ] Every text element has a non-empty `"text"` field
- [ ] Every container's `"boundElements"` array is non-empty
- [ ] Arrow labels (if any) also use bound text with `"containerId"`
