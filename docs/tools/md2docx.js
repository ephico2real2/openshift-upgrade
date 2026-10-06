// Convert one of the project's Markdown documents to a Word file.
//   node md2docx.js <input.md> <output.docx>
// Handles what these documents use: headings, paragraphs, pipe tables, bullet and numbered lists,
// fenced code, <picture> figures and inline `code`, **bold**, *italic* and links.
// ```text fences are the figures' text twins for readers of the Markdown; Word embeds the figure, so they are skipped.
const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, ImageRun, ExternalHyperlink, Table, TableRow, TableCell,
  HeadingLevel, AlignmentType, WidthType, ShadingType, BorderStyle, LevelFormat, Footer, PageNumber,
  TableLayoutType,
} = require("docx");

const [, , inPath, outPath] = process.argv;
const baseDir = path.dirname(inPath);
const lines = fs.readFileSync(inPath, "utf8").split("\n");

const BODY = "Arial", MONO = "Menlo";
const PAGE_W = 12240, PAGE_H = 15840, MARGIN = 1080;          // US Letter, 0.75" margins
const CONTENT_W = PAGE_W - 2 * MARGIN;                          // 10080 DXA = 7.0"
const INK = "18212C", MUTED = "58636F", RULE = "D7DCE3", HEAD_FILL = "EEF0F3", ACCENT = "0E6F68";

// ---- inline formatting ----------------------------------------------------------------------
function inline(text, base = {}) {
  base = { font: BODY, ...base };                              // named on every run: not every viewer honours the document default
  const out = [];
  const re = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|(\[[^\]]+\]\([^)]+\))|(<https?:\/\/[^>]+>)/g;
  let last = 0, m;
  const plain = (t) => { if (t) out.push(new TextRun({ text: t, ...base })); };
  while ((m = re.exec(text))) {
    plain(text.slice(last, m.index));
    const tok = m[0];
    if (m[1]) out.push(new TextRun({ ...base, text: tok.slice(1, -1), font: MONO, size: (base.size || 21) - 2 }));
    else if (m[2]) out.push(...inline(tok.slice(2, -2), { ...base, bold: true }));
    else if (m[3]) out.push(...inline(tok.slice(1, -1), { ...base, italics: true }));
    else if (m[4]) {
      const [, label, url] = tok.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
      const runs = inline(label, /^https?:/.test(url) ? { ...base, color: ACCENT, underline: {} } : base);
      // Relative links point at files in the repository; in a Word file only the label is meaningful.
      if (/^https?:/.test(url)) out.push(new ExternalHyperlink({ link: url, children: runs })); else out.push(...runs);
    } else {
      const url = tok.slice(1, -1);
      out.push(new ExternalHyperlink({ link: url, children: [new TextRun({ text: url, color: ACCENT, underline: {}, ...base })] }));
    }
    last = m.index + tok.length;
  }
  plain(text.slice(last));
  return out.flat();
}
const visibleLen = (s) => s.replace(/[`*]/g, "").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1").length;

// ---- block builders -------------------------------------------------------------------------
function table(rows, aligns, hasHeader) {
  const n = rows[0].length;
  // Width follows the longest cell in each column, within a floor and ceiling, then scaled to the page.
  const weight = Array.from({ length: n }, (_, c) => Math.min(60, Math.max(9, ...rows.map((r) => visibleLen(r[c] || "")))));
  const total = weight.reduce((a, b) => a + b, 0);
  const widths = weight.map((w) => Math.floor((w / total) * CONTENT_W));
  widths[n - 1] += CONTENT_W - widths.reduce((a, b) => a + b, 0);
  const border = { style: BorderStyle.SINGLE, size: 4, color: RULE };
  return new Table({
    width: { size: CONTENT_W, type: WidthType.DXA },
    columnWidths: widths,
    layout: TableLayoutType.FIXED,
    rows: rows.map((r, ri) => new TableRow({
      tableHeader: hasHeader && ri === 0,
      cantSplit: true,
      children: r.map((cell, ci) => new TableCell({
        width: { size: widths[ci], type: WidthType.DXA },
        margins: { top: 70, bottom: 70, left: 110, right: 110 },
        borders: { top: border, bottom: border, left: border, right: border },
        shading: hasHeader && ri === 0 ? { type: ShadingType.CLEAR, fill: HEAD_FILL, color: "auto" } : undefined,
        children: [new Paragraph({
          alignment: aligns[ci] === "right" ? AlignmentType.RIGHT : AlignmentType.LEFT,
          spacing: { before: 0, after: 0, line: 252 },
          children: inline(cell, hasHeader && ri === 0 ? { bold: true, size: 17, color: MUTED } : { size: 18 }),
        })],
      })),
    })),
  });
}

function pngSize(file) { const b = fs.readFileSync(file); return [b.readUInt32BE(16), b.readUInt32BE(20)]; }
function figure(src, alt) {
  const file = path.join(baseDir, src);
  const [w, h] = pngSize(file);
  const width = 672;                                            // 7.0" at 96 px per inch
  return new Paragraph({
    spacing: { before: 120, after: 80 }, keepNext: true,
    children: [new ImageRun({ type: "png", data: fs.readFileSync(file), transformation: { width, height: Math.round((width * h) / w) },
      altText: { title: path.basename(src), description: alt, name: path.basename(src) } })],
  });
}

// ---- parse ----------------------------------------------------------------------------------
const body = [];
let i = 0, title = "", listInstance = 0;
const splitRow = (l) => l.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
while (i < lines.length) {
  const l = lines[i];
  if (/^## Diagram sources/.test(l)) break;                     // how to re-render the PNGs: repository-only
  if (!l.trim()) { i++; continue; }
  let m;
  if ((m = l.match(/^(#{1,3}) (.*)$/))) {
    if (m[1].length === 1) { title = m[2]; body.push(new Paragraph({ heading: HeadingLevel.TITLE, children: inline(m[2]) })); }
    else body.push(new Paragraph({ heading: m[1].length === 2 ? HeadingLevel.HEADING_1 : HeadingLevel.HEADING_2, children: inline(m[2]) }));
    i++; continue;
  }
  if (l.startsWith("```")) {
    const lang = l.slice(3).trim(); const code = []; i++;
    while (!lines[i].startsWith("```")) code.push(lines[i++]);
    i++;
    if (lang === "text") continue;
    code.forEach((c, ci) => body.push(new Paragraph({
      spacing: { before: ci === 0 ? 100 : 0, after: ci === code.length - 1 ? 140 : 0, line: 240 },
      shading: { type: ShadingType.CLEAR, fill: "F5F6F8", color: "auto" },
      children: [new TextRun({ text: c || " ", font: MONO, size: 15, color: c.startsWith("#") ? MUTED : INK })],
    })));
    continue;
  }
  if (l.startsWith("<picture>")) {
    let block = ""; while (!lines[i].startsWith("</picture>")) block += lines[i++] + "\n"; i++;
    const src = block.match(/<source srcset="([^"]+\.light\.png)">/)[1];
    body.push(figure(src, block.match(/<img alt="([^"]*)"/)[1]));
    continue;
  }
  if (l.startsWith("|")) {
    const raw = []; while (i < lines.length && lines[i].startsWith("|")) raw.push(lines[i++]);
    const aligns = splitRow(raw[1]).map((c) => (/:$/.test(c) ? "right" : "left"));
    const header = splitRow(raw[0]); const rows = raw.slice(2).map(splitRow);
    const hasHeader = header.some((c) => c);                    // "| | |" marks a key/value table with no header row
    body.push(table(hasHeader ? [header, ...rows] : rows, aligns, hasHeader));
    body.push(new Paragraph({ spacing: { before: 0, after: 100 }, children: [] }));
    continue;
  }
  if ((m = l.match(/^(- |\d+\. )(.*)$/))) {
    const ordered = /^\d/.test(m[1]);
    if (ordered) listInstance++;                                // each numbered list restarts at 1
    while (i < lines.length && (m = lines[i].match(/^(- |\d+\. )(.*)$/))) {
      let item = m[2]; i++;
      while (i < lines.length && /^ {2,}\S/.test(lines[i])) item += " " + lines[i++].trim();
      body.push(new Paragraph({ numbering: { reference: ordered ? "numbers" : "bullets", level: 0, instance: ordered ? listInstance : 0 }, spacing: { before: 0, after: 80 }, children: inline(item) }));
    }
    continue;
  }
  let para = l; i++;
  while (i < lines.length && lines[i].trim() && !/^(#|\||```|<picture>|- |\d+\. )/.test(lines[i])) para += " " + lines[i++].trim();
  const caption = /^\*[^*].*\*$/.test(para);                    // a whole-paragraph italic is a figure caption
  body.push(new Paragraph({
    spacing: { before: 0, after: caption ? 200 : 140 },
    children: caption ? inline(para.slice(1, -1), { italics: true, color: MUTED, size: 19 }) : inline(para),
  }));
}

// ---- document -------------------------------------------------------------------------------
const heading = (size, before, after) => ({ run: { font: BODY, size, bold: true, color: INK }, paragraph: { spacing: { before, after }, keepNext: true } });
const doc = new Document({
  title, creator: "Platform engineering",
  styles: {
    default: { document: { run: { font: BODY, size: 21, color: INK }, paragraph: { spacing: { line: 288 } } } },
    paragraphStyles: [
      { id: "Title", name: "Title", basedOn: "Normal", next: "Normal", quickFormat: true, ...heading(40, 0, 220) },
      { id: "Heading1", name: "heading 1", basedOn: "Normal", next: "Normal", quickFormat: true, ...heading(28, 360, 140) },
      { id: "Heading2", name: "heading 2", basedOn: "Normal", next: "Normal", quickFormat: true, ...heading(23, 260, 100) },
    ],
  },
  numbering: { config: [
    { reference: "bullets", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 440, hanging: 260 } } } }] },
    { reference: "numbers", levels: [{ level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 440, hanging: 300 } } } }] },
  ] },
  sections: [{
    properties: { page: { size: { width: PAGE_W, height: PAGE_H }, margin: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN } } },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, children: [
      new TextRun({ text: `${title}  ·  page `, font: BODY, size: 16, color: MUTED }), new TextRun({ children: [PageNumber.CURRENT], font: BODY, size: 16, color: MUTED }),
    ] })] }) },
    children: body,
  }],
});
Packer.toBuffer(doc).then((buf) => { fs.writeFileSync(outPath, buf); console.log(`wrote ${outPath} (${buf.length} bytes, ${body.length} blocks)`); });
