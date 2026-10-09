# Decks

The two slide decks, as published on claude.ai, kept here as their source files so they are
versioned with the documents they present. Each deck is a `project/deck.json` index (title, slide
order, sections, typefaces) and one `project/slides/<id>.html` per slide, in the Slides artifact
format: a single `<section>` with inline styles and, last, an `<aside>` of speaker notes.

| Deck | Published at | Slides | Presents |
|---|---|---|---|
| [`openshift-update-plan/`](openshift-update-plan/) | https://claude.ai/artifact/Fo4b3ncXoHibc2Xo4p1ATY | 25 | [`../SOLUTIONS.md`](../SOLUTIONS.md), [`../PREREQUISITES.md`](../PREREQUISITES.md), [`../PROBLEM-STATEMENT.md`](../PROBLEM-STATEMENT.md), the recommendation and the decisions needed |
| [`threat-model/`](threat-model/) | https://claude.ai/artifact/WsUCY5bQkUzHVaKAtCKZgS | 12 | [`../enterprise-proxy/THREAT-MODEL.md`](../enterprise-proxy/THREAT-MODEL.md): the proxy approach as a threat model, who decides, and the one condition for security |

The slides embed figures as `/_blob/<id>` uploads of the artifact. Every one is a light PNG from
this repository, rendered with diagram-kit from the `source.html` beside it:

| Upload id | Repository figure | On slide |
|---|---|---|
| `8fbe951a2c8b412c9dff020decdbf0ff` | [`../diagrams/three-steps/three-steps.light.png`](../diagrams/three-steps/three-steps.light.png) | plan: `steps` |
| `6d0666dd2c2981c129bf8fdcae2e8d8d` | [`../../oc-mirror-ansible/docs/diagrams/mirroring/run-flow.light.png`](../../oc-mirror-ansible/docs/diagrams/mirroring/run-flow.light.png) | plan: `step1flow` |
| `0a3b7fe89702e3b1b2f4ff53ef425f24` | [`../diagrams/three-steps/retrofit.light.png`](../diagrams/three-steps/retrofit.light.png) | plan: `step2` |
| `93ca02d95972386d24f1b90e43bf3b1b`, `f4bde97f69fc9230c5dc5442e45045c1` | [`../enterprise-proxy/diagrams/threat-model/proxy-update-threat-model.light.png`](../enterprise-proxy/diagrams/threat-model/proxy-update-threat-model.light.png) | plan: `threatmodel`; threat model: `model` |
| `1929238e031f7f72a8fa4f713ab577ba`, `2dfbc875d3bfef4e77075359ecba47c5` | [`../enterprise-proxy/diagrams/threat-model/proxy-update-steps.light.png`](../enterprise-proxy/diagrams/threat-model/proxy-update-steps.light.png) | plan: `threatsteps`; threat model: `steps` |
| `5473f7abd3f5c90a897f4ca93c43cdeb` | [`../diagrams/three-steps/quay-sync.light.png`](../diagrams/three-steps/quay-sync.light.png) | plan: `step3` |
| `1c24524fe76df8ce57a95896e091c15a` | [`../diagrams/prerequisites/topology.light.png`](../diagrams/prerequisites/topology.light.png) | plan: `hosts` |
| `a1ce8ca7d9b4a7696ee5bf3c187b4234` | [`../diagrams/three-steps/decision.light.png`](../diagrams/three-steps/decision.light.png) | plan: `recommend` |

When a figure is re-rendered, upload the new PNG to the deck, point the slide's `<img src>` at the
new id, and update this table. When a slide changes, copy the published file back here. The text
on the slides follows the documents; the documents are the source of truth.
