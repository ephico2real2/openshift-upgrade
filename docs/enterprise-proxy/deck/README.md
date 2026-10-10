# Threat model deck

Source of the slide deck "Threat Model: Cluster Updates Through Our Proxy", 12 slides at 1920×1080.

- **View and download:** https://claude.ai/artifact/WsUCY5bQkUzHVaKAtCKZgS. Use **Download → PowerPoint (.pptx)**, then make a PDF from PowerPoint if needed.
- **Source:** `deck.json` holds the slide order and sections. `slides/<id>.html` holds each slide, with its speaker notes in `<aside>`.
- **Diagrams:** the slides load the two diagrams from the deck's own storage (`/_blob/...`), so they show only in the deck. They are the same figures as [`../diagrams/threat-model/`](../diagrams/threat-model/), with the references to this repository removed.

The slides themselves never reference this repository. Keep it that way when editing.

| # | Slide | Content |
|---|---|---|
| 1 | `cover` | Title |
| 2 | `why` | Why this change, and who decides |
| 3 | `shows` | What the threat model shows |
| 4 | `model` | Threat-model diagram |
| 5 | `callers` | Who calls which Red Hat host |
| 6 | `proxy` | Our enterprise proxy and firewall |
| 7 | `apppods` | Application pods cannot use the cluster proxy |
| 8 | `registries` | Only allowed registries: two layers |
| 9 | `steps` | The update step by step |
| 10 | `controls` | Eight controls and their Red Hat sources |
| 11 | `stops` | What the design stops |
| 12 | `next` | What we need |
