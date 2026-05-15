export type Frontmatter = Record<string, string | string[]>;

export function parseFrontmatter(markdown: string): { data: Frontmatter; body: string; raw: string } {
  if (!markdown.startsWith("---\n")) {
    return { data: {}, body: markdown, raw: "" };
  }

  const end = markdown.indexOf("\n---", 4);
  if (end < 0) {
    return { data: {}, body: markdown, raw: "" };
  }

  const raw = markdown.slice(4, end);
  const data: Frontmatter = {};
  for (const line of raw.split(/\r?\n/)) {
    const match = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(line);
    if (!match) continue;
    const [, key, rawValue] = match;
    data[key] = parseYamlScalarOrArray(rawValue.trim());
  }

  return {
    data,
    body: markdown.slice(markdown.indexOf("\n", end + 1) + 1),
    raw,
  };
}

export function setFrontmatterValue(markdown: string, key: string, value: string): string {
  if (!markdown.startsWith("---\n")) {
    return `---\n${key}: "${escapeYamlString(value)}"\n---\n\n${markdown}`;
  }

  const end = markdown.indexOf("\n---", 4);
  if (end < 0) {
    return `---\n${key}: "${escapeYamlString(value)}"\n---\n\n${markdown}`;
  }

  const raw = markdown.slice(4, end);
  const replacementLine = `${key}: "${escapeYamlString(value)}"`;
  const lines = raw.split(/\r?\n/);
  let replaced = false;
  const nextLines = lines.map((line) => {
    if (line.startsWith(`${key}:`)) {
      replaced = true;
      return replacementLine;
    }
    return line;
  });
  if (!replaced) nextLines.push(replacementLine);
  return `---\n${nextLines.join("\n")}\n---${markdown.slice(end + "\n---".length)}`;
}

export function frontmatterString(data: Frontmatter, key: string): string | undefined {
  const value = data[key];
  return typeof value === "string" ? value : undefined;
}

export function frontmatterArray(data: Frontmatter, key: string): string[] {
  const value = data[key];
  return Array.isArray(value) ? value : [];
}

function parseYamlScalarOrArray(value: string): string | string[] {
  if (value.startsWith("[") && value.endsWith("]")) {
    const inside = value.slice(1, -1).trim();
    if (!inside) return [];
    return inside.split(",").map((item) => stripYamlQuotes(item.trim())).filter(Boolean);
  }
  return stripYamlQuotes(value);
}

function stripYamlQuotes(value: string): string {
  if (
    (value.startsWith("\"") && value.endsWith("\""))
    || (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1);
  }
  return value;
}

function escapeYamlString(value: string): string {
  return value.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"");
}
