// Follows a URL the way a browser would for gh-touchid's flows: redirects across hosts, and pages with a form that
// posts itself (gh-touchid's manifest page) are submitted with their inputs. No script runs; a page with a POST form
// is taken to submit it on load, which is what gh-touchid's pages do.

export interface Visit {
  method: "GET" | "POST";
  url: string;
  status: number;
  /** Where a redirect pointed. */
  location?: string;
}

export interface BrowseResult {
  visits: Visit[];
  /** The last page: where the chain of redirects and forms ended. */
  url: string;
  status: number;
  body: string;
}

export interface Form {
  method: string;
  action: string;
  /** The inputs that have a name, values HTML-unescaped. */
  fields: Record<string, string>;
}

/** Follows `start` through redirects and self-posting forms, up to `maxSteps` requests. */
export async function browse(start: string, options: { maxSteps?: number } = {}): Promise<BrowseResult> {
  const visits: Visit[] = [];
  let request: { method: "GET" | "POST"; url: string; form?: Record<string, string> } = { method: "GET", url: start };
  for (let step = 0; step < (options.maxSteps ?? 20); step++) {
    const response = await fetch(request.url, {
      method: request.method,
      redirect: "manual",
      headers: request.form ? { "content-type": "application/x-www-form-urlencoded" } : {},
      body: request.form ? new URLSearchParams(request.form).toString() : undefined,
    });
    const body = await response.text();
    const location = response.headers.get("location") ?? undefined;
    visits.push({ method: request.method, url: request.url, status: response.status, location });
    if (response.status >= 300 && response.status < 400 && location) {
      request = { method: "GET", url: new URL(location, request.url).toString() };
      continue;
    }
    const form = response.ok ? parseForm(body) : undefined;
    if (form && form.method === "post") {
      request = { method: "POST", url: new URL(form.action, request.url).toString(), form: form.fields };
      continue;
    }
    return { visits, url: request.url, status: response.status, body };
  }
  throw new Error(`browsing ${start} took more than ${options.maxSteps ?? 20} requests: ${JSON.stringify(visits)}`);
}

/** The first form of an HTML page, or undefined when it has none. */
export function parseForm(html: string): Form | undefined {
  const opening = html.match(/<form\b([^>]*)>([\s\S]*?)(?:<\/form>|$)/i);
  if (!opening) {
    return undefined;
  }
  const attributes = parseAttributes(opening[1]!);
  const fields: Record<string, string> = {};
  for (const input of opening[2]!.matchAll(/<input\b([^>]*)>/gi)) {
    const inputAttributes = parseAttributes(input[1]!);
    if (inputAttributes.name !== undefined) {
      fields[inputAttributes.name] = inputAttributes.value ?? "";
    }
  }
  return {
    method: (attributes.method ?? "get").toLowerCase(),
    action: attributes.action ?? "",
    fields,
  };
}

function parseAttributes(text: string): Record<string, string> {
  const attributes: Record<string, string> = {};
  for (const match of text.matchAll(/([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g)) {
    attributes[match[1]!.toLowerCase()] = unescapeHTML(match[2] ?? match[3] ?? match[4] ?? "");
  }
  return attributes;
}

export function unescapeHTML(text: string): string {
  const named: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
  return text.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (entity, name: string) => {
    if (name.startsWith("#x") || name.startsWith("#X")) {
      return String.fromCodePoint(Number.parseInt(name.slice(2), 16));
    }
    if (name.startsWith("#")) {
      return String.fromCodePoint(Number.parseInt(name.slice(1), 10));
    }
    return named[name.toLowerCase()] ?? entity;
  });
}
