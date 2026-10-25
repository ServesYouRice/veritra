#!/usr/bin/env node
// Written by arbitra with this plan. It checks what one task's prompt names (files, names, routes, socket events,
// quoted code and cited lines) against the code as it is now, and prints what moved since the plan was saved, what
// is gone and what was never found. Plain Node 22 or later, no dependencies; it reads premises.json beside it.
//   node .arbitra/plans/<this folder>/check-premises.mjs TASK-012
// It checks the git working tree around the folder you run it from (a worktree too), or --root <dir>.
// Exit status: 0 when everything the prompt names is in the code, 1 when something is gone or was never found, 2 on a usage error.
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const kit = (function premiseKit() {
    const DOC = /\.(?:md|mdx|markdown|txt|rst|adoc)$/iu;
    const UNSEARCHED = /(?:^|\/)(?:package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|Cargo\.lock|poetry\.lock|composer\.lock|Gemfile\.lock|go\.sum|[^/]+\.min\.(?:js|css)|[^/]+\.map)$/u;
    const NEVER = /(?:^|\/)(?:node_modules|\.git|\.arbitra)(?:\/|$)/u;
    const TEST_FILE = /(?:^|\/)(?:tests?|__tests__|spec|e2e)\/|\.(?:test|spec)\.[a-z]+$|_test\.go$|(?:^|\/)test_[^/]+\.py$/u;
    const WALK_SKIP = new Set(["node_modules", ".git", ".arbitra", "dist", "build", "coverage", "out", ".next", ".nuxt", "target", ".venv", "venv", "__pycache__", ".cache", ".turbo"]);
    const MAX_BYTES = 1_000_000;
    const EXTENSIONS = "jsx|js|mjs|cjs|tsx|ts|mts|cts|jsonc|json|mdx|md|yml|yaml|html|htm|css|scss|sass|less|py|go|rs|java|kts|kt|rb|php|cs|cc|cpp|hpp|c|h|swift|sh|bash|ps1|psm1|bat|cmd|toml|ini|cfg|conf|xml|svg|sql|vue|svelte|astro|txt|env|gradle|proto|graphql|gql|plist|properties|tf";
    const PATH_SOURCE = `(?:\\.{1,2}/)?(?:[\\w@.-]+/)*[\\w@-][\\w@.-]*\\.(?:${EXTENSIONS})`;
    const PATH = new RegExp(`(?<![\\w@/.-])(${PATH_SOURCE})(?::(\\d+)(?:-(\\d+))?)?(?![\\w/-])`, "gu");
    const WHOLE_PATH = new RegExp(`^(${PATH_SOURCE})(?::(\\d+)(?:-(\\d+))?)?$`, "u");
    // `path:12-14`, `path:12: code`, `path (fn): 'code'` or `path fn: 'code'`.
    const QUOTE_HEADER = new RegExp(`^\\s*(${PATH_SOURCE})(?::(\\d+)(?:-(\\d+))?)?(?:\\s*\\([^)]*\\)|(?:\\s+[\\w.$#]+(?:\\(\\))?){1,3})?\\s*(?::\\s?(.*)|,.*)?\\s*$`, "u");
    const LINES_OF = new RegExp(`^\\s+(?:of|in)\\s+(${PATH_SOURCE})`, "u");
    const LINE_REF = /\b[Ll]ines?\s+(\d+)(?:\s*(?:-|–|to|through)\s*(\d+))?/gu;
    const ROUTE = /^(?:(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+)?(\/(?:[\w.:{}*$-]+(?:\/[\w.:{}*$-]*)*)?)(?:\?\S*)?$/u;
    // A route in prose starts a word: `min()/calc()` and `open/close` name none. Text already read is blanked with "#".
    const PROSE_ROUTE = /(?<=^|[\s([,])(?:(GET|POST|PUT|PATCH|DELETE)\s+)?(\/(?:[a-z][\w.-]*|:\w+|\{\w+\})(?:\/(?:[\w.-]+|:\w+|\{\w+\}|\*))*)(?![\w/(])/gu;
    const KEBAB = /^[a-z][a-z0-9]*(?:[-:][a-z0-9]+)+$/u;
    const SYMBOL = /^(?:new\s+)?([A-Za-z_$][\w$]*(?:\??\.[A-Za-z_$#][\w$]*)*)(?:\(\))?$/u;
    const IDS = /(?:section-[0-9a-f]{6,}\/)?\b(?:TASK|VAL|REQ|Q)-\d+\b|\bC-[0-9a-f]{6,}\b|\bsection-[0-9a-f]{6,}\b/gu;
    const URLS = /\bhttps?:\/\/[^\s)'"`>]+/gu;
    const ELISION = /\.\.\.|…|<[a-z][\w -]*>/u;
    const EVENT_CALL = /\.(?:on|once|off|emit|emitWithAck|addEventListener|removeEventListener|removeListener|handle|subscribe)\(\s*['"`]([^'"`]{1,80})['"`]/gu;
    const LITERALS = new Set(["true", "false", "null", "undefined", "NaN", "Infinity", "this", "self", "void", "none", "None", "nil"]);
    const KEYWORDS = new Set(["if", "else", "for", "while", "do", "switch", "case", "return", "await", "async", "function", "const", "let", "var", "new", "typeof", "catch", "try", "finally", "throw", "break", "continue", "import", "export", "default", "class", "extends", "yield", "delete", "in", "of", "instanceof", "with"]);
    const RECEIVERS = new Set(["this", "self", "window", "document", "globalThis", "global", "process", "console", "Math", "JSON", "Object", "Array", "Promise", "Number", "String", "Boolean", "Date", "Buffer", "module", "exports", "require", "Reflect", "Symbol", "Error", "URL", "navigator", "location"]);
    const COMMON_MEMBERS = new Set(["current", "length", "then", "catch", "finally", "push", "pop", "shift", "delete", "get", "set", "has", "add", "clear", "call", "apply", "bind", "toString", "value", "on", "once", "off", "emit", "stop", "start", "close", "open", "play", "pause", "send", "end", "write", "read", "map", "filter", "forEach", "some", "every", "find", "includes", "keys", "values", "entries", "size", "id", "name", "type", "data", "error", "message", "status", "result", "slice", "split", "join", "trim", "test", "exec", "match", "replace"]);
    const PRODUCT_NAMES = new Set(["WebRTC", "JavaScript", "TypeScript", "GitHub", "GitLab", "PowerShell", "YouTube", "OpenAI", "ChatGPT", "DevTools", "VSCode", "NodeJS", "NodeJs", "MacOS", "WhatsApp", "PostgreSQL", "MySQL", "SQLite", "MongoDB", "GraphQL", "OAuth", "ESLint", "WebKit", "WebAssembly", "LinkedIn", "PayPal", "OneDrive", "iCloud", "macOS", "iOS", "iPadOS", "iPhone", "iPad", "eBay", "FreeBSD", "OpenSSL", "LibreSSL", "WebM", "WebP"]);
    // Globals and Node modules: a member of one that the project's code never names is the platform's, not a false premise.
    const PLATFORM = new Set(["Promise", "Object", "Array", "Number", "String", "Boolean", "JSON", "Math", "Reflect", "Symbol", "Date", "Buffer", "Intl", "Atomics", "BigInt", "crypto", "net", "fs", "path", "os", "http", "https", "http2", "url", "util", "zlib", "stream", "events", "dgram", "dns", "tls", "child_process", "worker_threads", "process", "window", "document", "navigator", "console", "performance", "location", "history", "screen", "localStorage", "sessionStorage", "globalThis"]);
    const PLATFORM_CLASSES = /^(?:\w*(?:Error|Exception)|EventEmitters?|PassThrough|Readable|Writable|Duplex|Transform|IncomingMessage|ClientRequest|ServerResponse|AbortController|AbortSignal|MediaSource|SourceBuffer|MediaRecorder|MediaStream|MediaStreamTrack|RTC\w+|WebSocket|URLSearchParams|TextEncoder|TextDecoder|ReadableStream|WritableStream|TransformStream|ArrayBuffer|SharedArrayBuffer|DataView|\w+Array|WeakMap|WeakSet|WeakRef|FinalizationRegistry|EventTarget|CustomEvent|MessageChannel|MessagePort|BroadcastChannel|FormData|Headers|Request|Response|Blob|File|FileReader|IntersectionObserver|ResizeObserver|MutationObserver|HTMLElement|HTML\w+Element|DOMParser|XMLHttpRequest|Worker|ServiceWorker|Notification|Permissions?|Geolocation|IndexedDB|IDB\w+|AudioContext|AudioWorklet\w*|OfflineAudioContext|VideoFrame|VideoEncoder|VideoDecoder|AudioEncoder|AudioDecoder|EncodedVideoChunk|EncodedAudioChunk)$/u;
    const UNITS = /^(?:[KMGTP]i?B|[KMGT]bps|[kKM]?Hz|ms|fps)$/u;
    const DETERMINERS = new Set(["the", "a", "an", "its", "this", "that", "these", "those", "their", "our", "of", "to", "for", "from", "by", "on", "in", "with", "no", "any", "each", "every", "and", "or", "both", "all", "some", "two", "three", "four", "other", "another"]);
    const ENDPOINT_GENERIC = new Set(["write", "read", "update", "server", "client", "server-side", "client-side", "http", "https", "rest", "socket", "api", "web", "new", "existing", "same", "public", "private", "local", "remote", "internal", "external", "separate", "dedicated", "own", "one", "get", "post", "put", "delete", "patch", "which", "express", "router", "as", "such", "matching", "corresponding", "relevant", "real", "single", "second", "first", "previous", "current", "old", "sensitive"]);
    // An adjective before "endpoint" ("a fixed endpoint", "the non-public endpoint") describes it; it does not name it.
    const DESCRIBES = /(?:ed|ive|ous|less|able|ible|-only|-safe)$|^(?:non|un)-?/u;
    const CREATES = /\b(?:add|adds|adding|create|creates|creating|introduce|introduces|introducing|new|define|defines|defining|export|exports|exporting|expose|exposes|implement|implements|implementing|extract|named|called|e\.g\.|for example|such as|rename\w*|register|track|tracks|store|emit|emits|return|returns|replace\w*|wrap\w*|helper|split|move\w*)\b/iu;
    const ABSENT = /\b(?:no|not|never|without|lacks?|lacking|missing|nothing|none|neither|nor|cannot|can't|doesn't|isn't|absent|instead of)\b/iu;
    // An example ("e.g. via `NODE_TLS_REJECT_UNAUTHORIZED = '0'`") names no code that is there.
    const HYPOTHETICAL = /(?:\be\.g\.|\bfor example\b|\bsuch as\b|\bfor instance\b)/iu;
    const WINDOW = 200;
    // Statements all there in another order: the order can be the premise (nextra, October 2026: a prompt said a ref was
    // cleared before stop(), and the code cleared it after; that one was stated in prose, which no lookup can check).
    const REORDERED = "all of it is there, in another order than quoted";
    const NEAR = 120;
    // ---- reading a repository
    function nodeIo(modules, join) {
        const textOf = (bytes) => {
            for (const byte of bytes.subarray(0, 8000))
                if (byte === 0)
                    return null;
            return new TextDecoder("utf-8").decode(bytes);
        };
        const walk = (root, directory, found) => {
            let entries = [];
            try {
                entries = modules.readdirSync(directory === "" ? root : join(root, directory), { withFileTypes: true });
            }
            catch {
                return;
            }
            for (const entry of entries) {
                const path = directory === "" ? entry.name : `${directory}/${entry.name}`;
                if (entry.isDirectory()) {
                    if (!WALK_SKIP.has(entry.name) && !(entry.name.startsWith(".") && entry.name !== ".github"))
                        walk(root, path, found);
                }
                else if (entry.isFile())
                    found.push(path);
            }
        };
        return {
            // Git's view of the working tree (tracked files and new ones it does not ignore), or a walk where there is no Git.
            listFiles: (root) => {
                let listed = null;
                try {
                    listed = modules.execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], { cwd: root, encoding: "utf8", windowsHide: true, stdio: ["ignore", "pipe", "ignore"], maxBuffer: 64 * 1024 * 1024 })
                        .split("\0").filter((path) => path !== "");
                }
                catch {
                    listed = null;
                }
                const files = listed ?? (() => { const found = []; walk(root, "", found); return found; })();
                return [...new Set(files.map((path) => path.replace(/\\/gu, "/")))].filter((path) => !NEVER.test(path)).sort();
            },
            readText: (root, path) => {
                try {
                    const full = join(root, path);
                    const stat = modules.statSync(full, { throwIfNoEntry: false });
                    if (stat === undefined || !stat.isFile() || stat.size > MAX_BYTES)
                        return null;
                    return textOf(modules.readFileSync(full));
                }
                catch {
                    return null;
                }
            },
            exists: (root, path) => { try {
                return modules.statSync(join(root, path), { throwIfNoEntry: false }) !== undefined;
            }
            catch {
                return false;
            } },
        };
    }
    function indexRepository(root, io) {
        const files = io.listFiles(root);
        const contents = new Map();
        const content = (path) => {
            if (!contents.has(path))
                contents.set(path, io.readText(root, path));
            return contents.get(path) ?? null;
        };
        const searchable = files.filter((path) => !UNSEARCHED.test(path));
        const code = searchable.filter((path) => !DOC.test(path));
        const docs = searchable.filter((path) => DOC.test(path));
        const normalisedCache = new Map();
        const normalised = (path) => {
            if (!normalisedCache.has(path)) {
                const text = content(path);
                normalisedCache.set(path, text === null ? null : normalise(text));
            }
            return normalisedCache.get(path) ?? null;
        };
        const words = new Map();
        const literals = new Map();
        const events = new Set();
        let built = false;
        const build = () => {
            if (built)
                return;
            built = true;
            for (const path of code) {
                const text = content(path);
                if (text === null)
                    continue;
                text.split("\n").forEach((line, index) => {
                    for (const match of line.matchAll(/[A-Za-z_$][\w$]*/gu)) {
                        let entry = words.get(match[0]);
                        if (entry === undefined) {
                            entry = new Map();
                            words.set(match[0], entry);
                        }
                        if (!entry.has(path))
                            entry.set(path, index + 1);
                    }
                    for (const match of line.matchAll(/'((?:[^'\\]|\\.){1,200})'|"((?:[^"\\]|\\.){1,200})"|`((?:[^`\\]|\\.){1,200})`/gu)) {
                        const value = match[1] ?? match[2] ?? match[3] ?? "";
                        if (!literals.has(value))
                            literals.set(value, { path, start: index + 1, end: index + 1 });
                    }
                    for (const match of line.matchAll(EVENT_CALL))
                        if (match[1] !== undefined)
                            events.add(match[1]);
                });
            }
        };
        let names = null;
        return {
            root, files, fileSet: new Set(files), code, docs, content, normalised,
            words: () => { build(); return words; },
            literals: () => { build(); return literals; },
            events: () => { build(); return events; },
            byName: () => {
                if (names === null) {
                    const byName = new Map();
                    for (const path of files) {
                        const name = path.slice(path.lastIndexOf("/") + 1);
                        byName.set(name, [...byName.get(name) ?? [], path]);
                    }
                    names = byName;
                }
                return names;
            },
        };
    }
    function normalise(text) {
        const out = [];
        const lines = [];
        let line = 1;
        for (let index = 0; index < text.length; index += 1) {
            const code = text.charCodeAt(index);
            if (code === 10) {
                line += 1;
                continue;
            }
            if (code === 32 || code === 9 || code === 13 || code === 11 || code === 12 || code === 0xa0 || code === 0xfeff)
                continue;
            out.push(code === 34 || code === 96 || code === 0x2018 || code === 0x2019 || code === 0x201c || code === 0x201d ? "'" : text[index] ?? "");
            lines.push(line);
        }
        return { text: out.join(""), lineAt: Int32Array.from(lines) };
    }
    const flat = (text) => normalise(text.replace(/…/gu, "...")).text;
    // ---- reading a prompt's text
    /** Backticked, quoted and fenced spans, left to right, none inside another. */
    function quotedSpans(text) {
        const found = [];
        let index = 0;
        while (index < text.length) {
            const char = text[index] ?? "";
            let span = null;
            if (text.startsWith("```", index)) {
                const close = text.indexOf("```", index + 3);
                if (close > 0)
                    span = { start: index, end: close + 3, inner: text.slice(index + 3, close).replace(/^[\w-]*\n/u, ""), mark: "`" };
            }
            else if (char === "`") {
                const close = text.indexOf("`", index + 1);
                const inner = close < 0 ? "" : text.slice(index + 1, close);
                if (close > 0 && !inner.includes("\n"))
                    span = { start: index, end: close + 1, inner, mark: "`" };
            }
            else if (char === "'" || char === "\"" || char === "“" || char === "‘")
                span = quotation(text, index);
            if (span !== null && span.inner.trim() !== "") {
                found.push(span);
                index = span.end;
            }
            else
                index += 1;
        }
        return found;
    }
    function quotation(text, open) {
        const char = text[open] ?? "";
        const closer = char === "“" ? "”" : char === "‘" ? "’" : char;
        // An apostrophe, as in "the host's", opens nothing.
        if (open > 0 && /[\w$'’]/u.test(text[open - 1] ?? "") && char !== "“")
            return null;
        if (/\s/u.test(text[open + 1] ?? " "))
            return null;
        let first = null;
        for (let at = open + 1; at < text.length && at - open < 800; at += 1) {
            const current = text[at];
            if (current === "\n")
                break;
            if (current !== closer)
                continue;
            // A closing quote is followed by the end, a space, or closing punctuation and then one of those (`'x').`).
            let next = at + 1;
            while (next < text.length && /[.,;:!?)\]]/u.test(text[next] ?? ""))
                next += 1;
            const closes = next >= text.length || /\s/u.test(text[next] ?? "");
            if (!closes || /\s/u.test(text[at - 1] ?? ""))
                continue;
            // Past a sentence's end, or a run of plain words, this was an apostrophe or a quotation of prose.
            if (/[a-z]\.\s+[A-Z]|\b[a-z]+ [a-z]+ [a-z]+ [a-z]+ [a-z]+\b/u.test(text.slice(open + 1, at)))
                break;
            first ??= at;
            // A quote of code holds quotes of its own: close where its brackets balance.
            if (balanced(text.slice(open + 1, at)))
                return { start: open, end: at + 1, inner: text.slice(open + 1, at), mark: char };
        }
        return first === null ? null : { start: open, end: first + 1, inner: text.slice(open + 1, first), mark: char };
    }
    function balanced(inner) {
        let depth = 0;
        for (const char of inner) {
            if (char === "(" || char === "[" || char === "{")
                depth += 1;
            else if (char === ")" || char === "]" || char === "}") {
                depth -= 1;
                if (depth < 0)
                    return false;
            }
        }
        return depth === 0;
    }
    /** What a quoted span names, or null for a value, a number or a quotation from prose. */
    function classify(inner, mark) {
        const text = inner.trim();
        const path = WHOLE_PATH.exec(text);
        if (path?.[1] !== undefined)
            return { kind: "path", text: path[1], ...(path[2] === undefined ? {} : { lines: [Number(path[2]), Number(path[3] ?? path[2])] }) };
        if (ROUTE.test(text) && /[a-z]/iu.test(text) && !text.includes("//"))
            return { kind: "route", text };
        if (KEBAB.test(text))
            return { kind: "event", text };
        const symbol = SYMBOL.exec(text);
        if (symbol?.[1] !== undefined) {
            const name = symbol[1];
            if (LITERALS.has(name) || KEYWORDS.has(name) || UNITS.test(name) || /^[A-Za-z]$|^[a-z]{2}$/u.test(name))
                return null;
            // A plain word in quotation marks ('backwards', 'loopback') is a value or a manner of speaking, not a name.
            return mark !== "`" && /^[a-z]+$|^[A-Z][a-z]+$/u.test(name) && !text.endsWith(")") ? null : { kind: "symbol", text: name };
        }
        if (/^[-+]?(?:0x[\da-f]+|\d[\d_.,]*(?:e\d+)?)\s*[a-z%]{0,3}$/iu.test(text) || /^[\d.:/a-f]+$/iu.test(text))
            return null;
        if (mark === "`")
            return flat(text).length >= 6 ? { kind: "quote", text } : null;
        // A quotation from prose is code only when it reads like code.
        return /[(){}[\];=<>]|=>|\w\.\w/u.test(text) && flat(text).length >= 8 && flat(text).length <= 400 ? { kind: "quote", text } : null;
    }
    /** Everything a prompt's text names: files, symbols, routes, socket events, quoted code and cited lines. */
    function extract(sources) {
        const all = sources.flatMap(({ text, role, list }) => extractOne(text, role, list === true));
        // One premise per thing named; "to create" or "said to be missing" anywhere holds for every mention.
        const merged = new Map();
        for (const premise of all) {
            // `transaction.registerUndo` and `registerUndo` name one thing.
            const key = `${premise.kind}:${premise.kind === "quote" ? flat(premise.text) : premise.kind === "symbol" ? lookupName(premise.text) : premise.text}`;
            const earlier = merged.get(key);
            merged.set(key, earlier === undefined ? premise : mergePremises(earlier, premise));
        }
        return [...merged.values()];
    }
    function mergePremises(a, b) {
        const expected = a.expected ?? b.expected;
        return { kind: a.kind, text: a.text, role: a.role === "premise" || b.role === "premise" ? "premise" : "change", ...(a.words === undefined ? {} : { words: a.words }),
            ...(a.bare === true && b.bare === true ? { bare: true } : {}), ...(a.creates === true || b.creates === true ? { creates: true } : {}),
            ...(a.absent === true || b.absent === true ? { absent: true } : {}), ...(expected === undefined ? {} : { expected }) };
    }
    function extractOne(source, role, list) {
        const found = [];
        let text = source;
        const blank = (start, end) => { text = text.slice(0, start) + text.slice(start, end).replace(/[^\n]/gu, "#") + text.slice(end); };
        const push = (at, premise, listed = false) => {
            // "e.g. " ends no sentence.
            const before = text.slice(0, at).replace(/\b(e\.g|i\.e|etc|vs|cf)\.\s/gu, "$1._");
            const sentence = before.slice(Math.max(before.lastIndexOf(". "), before.lastIndexOf("\n"), before.lastIndexOf("; ")) + 1);
            const clause = sentence.slice(Math.max(sentence.lastIndexOf(","), sentence.lastIndexOf(":")) + 1);
            // A listed file the repository lacks is one the prompt lists under <new_files>.
            const creates = listed || (role === "change" && CREATES.test(sentence)) || /^\s*(?:add|create|new)\b/iu.test(sentence) || HYPOTHETICAL.test(clause);
            const absent = role === "premise" && ABSENT.test(clause);
            found.push({ at, premise: { ...premise, role, ...(creates ? { creates: true } : {}), ...(absent ? { absent: true } : {}) } });
        };
        // Quote blocks from the audit: a `path:lines` header, then the lines it quotes, which are one excerpt. Lines with no
        // header, or joined with " | " (a plan's own copy of a block, on one line), are each an excerpt of their own.
        for (const block of source.matchAll(/<quotes>([\s\S]*?)<\/quotes>/gu)) {
            const start = block.index;
            let current = null;
            const flush = () => {
                if (current === null)
                    return;
                const { path, lines, code, apart } = current;
                if (path !== null)
                    push(start, { kind: "path", text: path });
                const unquote = (line) => line.trim().replace(/^(['"`])(.*)\1$/u, "$2");
                const excerpts = apart || lines === null ? code.map(unquote) : [code.join("\n")];
                for (const excerpt of excerpts.filter((excerpt) => flat(excerpt).length >= 8)) {
                    push(start, { kind: "quote", text: excerpt.trim(), ...(path === null ? {} : { expected: { path, start: lines?.[0] ?? 0, end: lines?.[1] ?? 0 } }) });
                }
                current = null;
            };
            for (const row of (block[1] ?? "").split("\n")) {
                const pieces = row.split(/ \| |(?<=['"`])\s+\/\s+(?=['"`])/u);
                for (const line of pieces) {
                    const header = QUOTE_HEADER.exec(line);
                    if (header?.[1] !== undefined && (header[2] !== undefined || line.trim().endsWith(":") || header[4] !== undefined)) {
                        flush();
                        current = { path: header[1], lines: header[2] === undefined ? null : [Number(header[2]), Number(header[3] ?? header[2])], code: header[4] === undefined || header[4].trim() === "" ? [] : [header[4]], apart: pieces.length > 1 };
                    }
                    else {
                        current ??= { path: null, lines: null, code: [], apart: true };
                        current.code.push(line);
                        if (pieces.length > 1)
                            current.apart = true;
                    }
                }
            }
            flush();
            blank(start, start + block[0].length);
        }
        // Quoted spans are read before addresses and ids are blanked, so a quote keeps the URL it holds.
        const unblanked = text;
        text = text.replace(URLS, (url) => "#".repeat(url.length)).replace(IDS, (id) => "#".repeat(id.length));
        const spans = quotedSpans(unblanked).map((span) => ({ span, named: classify(span.inner, span.mark) })).filter(({ named }) => named !== null);
        const inside = (at) => spans.some(({ span }) => at >= span.start && at < span.end);
        // Line references, each with the path it names, to give the quote after it its place.
        const refs = [];
        const paths = [];
        for (const match of text.matchAll(PATH)) {
            if (match[1] === undefined || inside(match.index))
                continue;
            paths.push({ start: match.index, end: match.index + match[0].length, path: match[1] });
            if (match[2] !== undefined)
                refs.push({ start: match.index, end: match.index + match[0].length, path: match[1], lines: [Number(match[2]), Number(match[3] ?? match[2])], used: false });
        }
        for (const match of text.matchAll(LINE_REF)) {
            if (inside(match.index))
                continue;
            const lines = [Number(match[1]), Number(match[2] ?? match[1])];
            const end = match.index + match[0].length;
            const after = LINES_OF.exec(text.slice(end));
            const before = [...paths].reverse().find((path) => path.end <= match.index);
            const path = after?.[1] ?? before?.path;
            if (path !== undefined && lines[1] >= lines[0])
                refs.push({ start: match.index, end: end + (after?.[0].length ?? 0), path, lines, used: false });
        }
        for (const { span, named } of spans)
            if (named?.kind === "path" && named.lines !== undefined)
                refs.push({ start: span.start, end: span.end, path: named.text, lines: named.lines, used: true });
        refs.sort((a, b) => a.start - b.start);
        const refFor = (at) => {
            const ref = [...refs].reverse().find((candidate) => candidate.end <= at);
            return ref !== undefined && !/(?:\.\s|;\s|\n)/u.test(text.slice(ref.end, at)) ? ref : undefined;
        };
        for (const { span, named } of spans) {
            if (named === null)
                continue;
            if (named.kind === "quote") {
                const ref = refFor(span.start);
                if (ref !== undefined)
                    ref.used = true;
                push(span.start, { kind: "quote", text: named.text, ...(ref === undefined ? {} : { expected: { path: ref.path, start: ref.lines[0], end: ref.lines[1] } }) });
            }
            else
                push(span.start, { kind: named.kind, text: named.text });
        }
        for (const { span } of spans)
            blank(span.start, span.end);
        for (const ref of refs)
            if (!ref.used && ref.lines[1] - ref.lines[0] < 400)
                push(ref.start, { kind: "lines", text: `${ref.path}:${ref.lines[0]}${ref.lines[1] === ref.lines[0] ? "" : `-${ref.lines[1]}`}`, expected: { path: ref.path, start: ref.lines[0], end: ref.lines[1] } });
        for (const { start, end, path } of paths) {
            push(start, { kind: "path", text: path, ...(path.includes("/") || list ? {} : { bare: true }) }, list);
            blank(start, end);
        }
        for (const match of text.matchAll(PROSE_ROUTE)) {
            const route = match[0].trim().replace(/[.]+$/u, "");
            if (match[2] === undefined || !/[a-z]/iu.test(match[2]) || match[2].replace(/[.]+$/u, "").length <= 2)
                continue;
            push(match.index, { kind: "route", text: route });
            blank(match.index, match.index + match[0].length);
        }
        // An endpoint named in prose ("the restore endpoint"): the words after the last determiner name it, less those
        // that only describe it ("a fixed endpoint").
        for (const match of text.matchAll(/\b((?:[\w'-]+\s+){0,2})endpoints?\b/giu)) {
            const words = (match[1] ?? "").trim().split(/\s+/u).filter((word) => word !== "").map((word) => word.toLowerCase().replace(/'s$/u, ""));
            let last = -1;
            words.forEach((word, index) => { if (DETERMINERS.has(word))
                last = index; });
            const terms = words.slice(last + 1).filter((word) => !ENDPOINT_GENERIC.has(word) && !DESCRIBES.test(word) && /^[a-z][\w-]*$/u.test(word));
            if (terms.length > 0)
                push(match.index, { kind: "route", text: `${terms.join(" ")} endpoint`, words: terms });
        }
        for (const match of text.matchAll(/\b([a-z][a-z0-9]*(?:-[a-z0-9]+)+)\s+(?:socket\s+)?events?\b/gu)) {
            if (match[1] !== undefined && !DESCRIBES.test(match[1]) && !/^(?:top|low|high|long|short|end|real|one|two|first|last)-/u.test(match[1]))
                push(match.index, { kind: "event", text: match[1] });
        }
        // Code-shaped names in prose: calls, member chains, camelCase, PascalCase, snake_case and CONSTANT_CASE.
        const shapes = [
            [/(?<![\w$.#-])([A-Za-z_$][\w$]*(?:\??\.[A-Za-z_$][\w$]*)*)\((?=[^)]{0,80}\))/gu, true],
            [/(?<![\w$./#-])([A-Za-z_$][\w$]*(?:\??\.[A-Za-z_$][\w$]*)+)(?![\w$(-])/gu, false],
            [/(?<![\w$./#-])([a-z][a-z0-9]*[A-Z][A-Za-z0-9]*)(?![\w$-])/gu, false],
            [/(?<![\w$./#-])([A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*)(?![\w$-])/gu, false],
            [/(?<![\w$./#-])([a-z][a-z0-9]*(?:_[a-z0-9]+)+)(?![\w$-])/gu, false],
            [/(?<![\w$./#-])([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)(?![\w$-])/gu, false],
        ];
        for (const [pattern, call] of shapes) {
            for (const match of text.matchAll(pattern)) {
                const name = match[1];
                if (name === undefined || KEYWORDS.has(name) || LITERALS.has(name) || PRODUCT_NAMES.has(name) || UNITS.test(name) || /^\d/u.test(name))
                    continue;
                const segments = name.replace(/\?\./gu, ".").split(".");
                // A member chain counts when it reads as code (a camelCase or snake_case part); a call needs a name of 3 letters.
                if (!call && segments.length > 1 && !segments.some((segment) => /[a-z][A-Z]|_/u.test(segment)))
                    continue;
                if (call && segments.length === 1 && name.length < 3)
                    continue;
                push(match.index, { kind: "symbol", text: name });
                blank(match.index, match.index + name.length);
            }
        }
        return found.sort((a, b) => a.at - b.at).map(({ premise }) => premise);
    }
    // ---- resolving against a repository
    const located = (place, note) => ({ status: "found", place, ...(note === undefined ? {} : { note }) });
    const missing = (note) => ({ status: "missing", place: null, note });
    /** A premise against a repository; `near` is where it was last seen, to choose among several places. */
    function resolve(premise, repo, hints, near = null) {
        const expected = premise.expected === undefined ? null : { ...premise.expected, path: resolvePath(premise.expected.path, repo).place?.path ?? premise.expected.path };
        switch (premise.kind) {
            case "path": return resolvePath(premise.text, repo);
            case "symbol": return resolveSymbol(premise.text, repo, hints);
            case "event": return resolveEvent(premise.text, repo);
            case "route": return premise.words === undefined ? resolveRoute(premise.text, repo) : resolveNamedEndpoint(premise.words, repo);
            case "quote": return locate(premise.text, repo, hints, near ?? expected);
            case "lines": return resolveLines(premise, repo, near ?? expected);
        }
    }
    function resolvePath(text, repo) {
        const path = text.replace(/^\.\//u, "");
        if (repo.fileSet.has(path))
            return located({ path, start: 0, end: 0 });
        if (repo.files.some((file) => file.startsWith(`${path}/`)))
            return located({ path, start: 0, end: 0 }, "a folder");
        if (!path.includes("/")) {
            const named = repo.byName().get(path) ?? [];
            if (named[0] !== undefined)
                return located({ path: named[0], start: 0, end: 0 }, named.length === 1 ? undefined : `${named.length} files have this name`);
        }
        else {
            // A path given from another folder (`lib/x.js` for `src/lib/x.js`).
            const suffix = repo.files.filter((file) => file.endsWith(`/${path}`));
            if (suffix.length === 1 && suffix[0] !== undefined)
                return located({ path: suffix[0], start: 0, end: 0 }, `at ${suffix[0]}`);
        }
        return missing("no such file");
    }
    function definitionPattern(name) {
        const n = name.replace(/[$]/gu, "\\$");
        return new RegExp(`(?:\\bfunction\\s*\\*?\\s*${n}\\b|\\b(?:class|interface|type|enum|struct|trait|def|fn|func|fun|module|namespace)\\s+${n}\\b|\\b(?:const|let|var)\\s+${n}\\b\\s*=|^\\s*(?:export\\s+)?(?:default\\s+)?(?:static\\s+)?(?:async\\s+)?(?:get\\s+|set\\s+)?\\*?${n}\\s*\\([^)]*\\)\\s*(?::[^{]*)?\\{|(?<![\\w$.])${n}\\s*[:=]\\s*(?:async\\s*)?(?:function\\b|\\([^)]*\\)\\s*=>|[A-Za-z_$][\\w$]*\\s*=>)|\\bfunc\\s*\\([^)]*\\)\\s*${n}\\b|^\\s*${n}\\s*=[^=])`, "u");
    }
    /** The identifier a symbol is looked up by: its last part, or the part before a common member (`ref.current` is `ref`). */
    function lookupName(text) {
        const segments = text.replace(/^new\s+/u, "").replace(/\?\./gu, ".").split(/[.#]/u).filter((segment) => segment !== "" && !RECEIVERS.has(segment));
        const last = segments[segments.length - 1] ?? "";
        return COMMON_MEMBERS.has(last) && segments.length > 1 ? segments[segments.length - 2] ?? last : last;
    }
    function resolveSymbol(text, repo, hints) {
        const name = lookupName(text);
        const head = text.replace(/^new\s+/u, "").split(/[.?#]/u)[0] ?? "";
        if (name === "")
            return located({ path: "", start: 0, end: 0 }, "a built-in");
        const where = repo.words().get(name);
        if (where === undefined || where.size === 0) {
            // A name the code uses as the start of a longer one: "the HowTo view" for `HowToView`.
            const longer = name.length < 4 ? undefined : [...repo.words()].find(([word]) => word.length > name.length && word.startsWith(name) && /[A-Z_]/u.test(word[name.length] ?? ""));
            if (longer !== undefined) {
                const [word, files] = longer;
                const path = hints.find((hint) => files.has(hint)) ?? [...files.keys()].find((file) => !TEST_FILE.test(file)) ?? [...files.keys()][0] ?? "";
                return located({ path, start: files.get(path) ?? 0, end: files.get(path) ?? 0 }, `as part of \`${word}\``);
            }
            // The platform's own names (`Promise.allSettled`, `RangeError`, `net.isIP`) are not the project's to have.
            if ((PLATFORM.has(head) && head !== name) || PLATFORM_CLASSES.test(name))
                return located({ path: "", start: 0, end: 0 }, "a built-in");
            // A name only the documentation uses (a product, a protocol) is not in the code, but it is not a false premise either.
            if (/^[A-Z]/u.test(name) && repo.docs.some((path) => new RegExp(`\\b${name.replace(/[$]/gu, "\\$")}\\b`, "u").test(repo.content(path) ?? "")))
                return located({ path: "", start: 0, end: 0 }, "only in the documentation");
            return missing("not in the code");
        }
        // Where the code defines it, else where the code uses it; a test's stand-in for it only when no other code has it.
        const files = [...hints.filter((path) => where.has(path)), ...[...where.keys()].filter((path) => !hints.includes(path))];
        const pattern = definitionPattern(name);
        for (const group of [files.filter((path) => !TEST_FILE.test(path)), files.filter((path) => TEST_FILE.test(path))]) {
            for (const path of group) {
                const index = (repo.content(path) ?? "").split("\n").findIndex((line) => pattern.test(line));
                if (index >= 0)
                    return located({ path, start: index + 1, end: index + 1 }, "defined");
            }
            const first = group[0];
            if (first !== undefined) {
                const line = where.get(first) ?? 0;
                return located({ path: first, start: line, end: line }, where.size === 1 ? "used" : `used in ${where.size} files`);
            }
        }
        return missing("not in the code");
    }
    function resolveEvent(name, repo) {
        const literal = repo.literals().get(name);
        if (literal !== undefined)
            return located(literal);
        for (const path of repo.code) {
            const text = repo.content(path);
            const at = text?.indexOf(name) ?? -1;
            if (text !== null && at >= 0) {
                const line = text.slice(0, at).split("\n").length;
                return located({ path, start: line, end: line });
            }
        }
        return missing("no string in the code has this name");
    }
    const routeSegments = (route) => route.replace(/\?.*$/u, "").replace(/\$\{[^}]*\}/gu, ":").split("/").filter((segment) => segment !== "")
        .map((segment) => /^[:{*(]/u.test(segment) ? ":" : segment.toLowerCase());
    function resolveRoute(text, repo) {
        const wanted = routeSegments(text.replace(/^[A-Z]+\s+/u, ""));
        if (wanted.length === 0)
            return located({ path: "", start: 0, end: 0 }, "the root");
        // The route's path; or a router's own path (`/watch/:id`) under the path it is mounted at (`/whep`). A concrete
        // value (`/whip/AB12CD`) stands for a parameter.
        const routes = [...repo.literals()].filter(([literal]) => literal.startsWith("/")).map(([literal, place]) => ({ segments: routeSegments(literal), place }));
        const fits = (segments, part) => segments.length === part.length
            && segments.every((segment, index) => segment === ":" || part[index] === ":" || segment === part[index]);
        const named = (segments) => segments.some((segment) => segment !== ":");
        for (let split = 0; split < wanted.length; split += 1) {
            const head = wanted.slice(0, split);
            const tail = wanted.slice(split);
            const mounted = head.length === 0 || routes.some(({ segments }) => fits(segments, head) && named(segments));
            const own = routes.find(({ segments }) => fits(segments, tail) && (head.length > 0 || named(segments)));
            if (mounted && own !== undefined)
                return located(own.place, split === 0 ? undefined : `under /${head.join("/")}`);
        }
        return missing("no route in the code has this path");
    }
    function resolveNamedEndpoint(words, repo) {
        const events = repo.events();
        for (const [literal, place] of repo.literals()) {
            if (!(literal.startsWith("/") || KEBAB.test(literal) || events.has(literal)))
                continue;
            const name = literal.toLowerCase();
            if (words.some((word) => name.includes(word)))
                return located(place, `\`${literal}\``);
        }
        return missing("no HTTP route or socket event in the code has this name");
    }
    /**
     * A quote's place. All of it, its elided parts in order, in one file; else its statements in order near each other,
     * or its words in order (code quoted with other spacing or punctuation); else as much of it as is there. Of several
     * places, the one nearest `near` (where the prompt puts it, or where the plan saw it).
     */
    function locate(text, repo, hints, near) {
        const parts = text.split(ELISION).map(flat).filter((part) => part.length >= 3);
        if (parts.length === 0)
            return located({ path: "", start: 0, end: 0 }, "too short to look for");
        const order = [...new Set([...near === null ? [] : [near.path], ...hints, ...repo.code, ...hints.filter((path) => repo.docs.includes(path))])].filter((path) => repo.fileSet.has(path));
        const distance = (path, line) => near === null || near.path !== path ? Number.MAX_SAFE_INTEGER : Math.abs(line - near.start);
        // A quoted call may leave out its other arguments (`on('close')` for `on('close', handler)`).
        const last = parts[parts.length - 1] ?? "";
        const open = last.replace(/[)\];,]+$/u, "");
        for (const candidate of [parts, ...open !== last && open.length >= 10 ? [[...parts.slice(0, -1), open]] : []]) {
            for (const path of order) {
                const file = repo.normalised(path);
                if (file === null || !file.text.includes(candidate[0] ?? ""))
                    continue;
                const hits = inOrder(file, candidate, distance(path, 0) !== Number.MAX_SAFE_INTEGER ? 50 : 1);
                const hit = [...hits].sort((a, b) => distance(path, a[0]) - distance(path, b[0]))[0];
                if (hit !== undefined)
                    return located({ path, start: hit[0], end: hit[1] }, candidate === parts ? undefined : "its other arguments left out");
            }
        }
        // A quote of several lines is checked line by line; a quote on one line, statement by statement.
        const fragments = (text.includes("\n") ? text.split("\n").map(flat) : parts.flatMap((part) => part.split(/[;{}]/u))).filter((fragment) => fragment.length >= 5);
        const words = text.split(ELISION).flatMap((part) => part.split(/\s+/u)).map((word) => flat(word).replace(/^[;,]+|[;,]+$/gu, "")).filter((word) => word.length >= 2);
        const statements = fragments.length >= 2 ? sequence(order, repo, fragments, distance) : null;
        if (statements !== null && statements.unmatched.length === 0)
            return located(statements.place, "in parts");
        const spaced = words.length >= 3 ? sequence(order, repo, words, distance) : null;
        if (spaced !== null && spaced.unmatched.length === 0)
            return located(spaced.place, "in parts");
        if (statements === null)
            return missing("not in the code");
        if (statements.unordered)
            return { status: "partial", place: statements.place, unmatched: statements.unmatched, note: REORDERED };
        const share = statements.unmatched.reduce((sum, fragment) => sum + fragment.length, 0) / fragments.reduce((sum, fragment) => sum + fragment.length, 0);
        return share >= 0.6 ? missing("not in the code") : { status: "partial", place: statements.place, unmatched: statements.unmatched, note: "only part of it is in the code" };
    }
    /** Where the most of `elements` appear in their order within 60 lines of the longest; and whether the rest are there out of order. */
    function sequence(order, repo, elements, distance) {
        const anchorIndex = elements.reduce((best, element, index) => element.length > (elements[best] ?? "").length ? index : best, 0);
        const anchor = elements[anchorIndex] ?? "";
        let best = null;
        for (const path of order) {
            const file = repo.normalised(path);
            if (file === null)
                continue;
            const lineOf = (at) => file.lineAt[at] ?? 0;
            for (let at = file.text.indexOf(anchor), tries = 0; at >= 0 && tries < 20; at = file.text.indexOf(anchor, at + 1), tries += 1) {
                const line = lineOf(at);
                let first = at;
                let last = at + anchor.length - 1;
                const unmatched = [];
                let cursor = at + anchor.length;
                for (const element of elements.slice(anchorIndex + 1)) {
                    const next = file.text.indexOf(element, cursor);
                    if (next >= 0 && lineOf(next) - line <= NEAR) {
                        cursor = next + element.length;
                        last = Math.max(last, cursor - 1);
                    }
                    else
                        unmatched.push(element);
                }
                cursor = at;
                for (const element of elements.slice(0, anchorIndex).reverse()) {
                    const previous = cursor - element.length < 0 ? -1 : file.text.lastIndexOf(element, cursor - element.length);
                    if (previous >= 0 && line - lineOf(previous) <= NEAR) {
                        cursor = previous;
                        first = Math.min(first, previous);
                    }
                    else
                        unmatched.unshift(element);
                }
                const nearby = unmatched.map((element) => {
                    for (let other = file.text.indexOf(element); other >= 0; other = file.text.indexOf(element, other + 1))
                        if (Math.abs(lineOf(other) - line) <= NEAR)
                            return [other, other + element.length - 1];
                    return null;
                });
                const unordered = unmatched.length > 0 && nearby.every((span) => span !== null);
                if (unordered)
                    for (const span of nearby)
                        if (span !== null) {
                            first = Math.min(first, span[0]);
                            last = Math.max(last, span[1]);
                        }
                const score = elements.length - unmatched.length;
                const away = distance(path, line);
                if (best === null || score > best.score || (score === best.score && away < best.distance))
                    best = { place: { path, start: lineOf(first), end: lineOf(last) }, unmatched, unordered, score, distance: away };
                if (unmatched.length === 0 && away === Number.MAX_SAFE_INTEGER)
                    break;
            }
            if (best !== null && best.unmatched.length === 0 && best.distance === Number.MAX_SAFE_INTEGER)
                break;
        }
        return best === null ? null : { place: best.place, unmatched: best.unmatched, unordered: best.unordered };
    }
    /** Each place where `parts` appear in order, each within the window of the first, up to `limit` places. */
    function inOrder(file, parts, limit) {
        const head = parts[0] ?? "";
        const hits = [];
        for (let at = file.text.indexOf(head), tries = 0; at >= 0 && tries < 200 && hits.length < limit; at = file.text.indexOf(head, at + 1), tries += 1) {
            let cursor = at + head.length;
            let ok = true;
            for (const part of parts.slice(1)) {
                const next = file.text.indexOf(part, cursor);
                if (next < 0 || (file.lineAt[next] ?? 0) - (file.lineAt[at] ?? 0) > WINDOW) {
                    ok = false;
                    break;
                }
                cursor = next + part.length;
            }
            if (ok)
                hits.push([file.lineAt[at] ?? 0, file.lineAt[cursor - 1] ?? 0]);
        }
        return hits;
    }
    function resolveLines(premise, repo, near) {
        const expected = premise.expected;
        if (expected === undefined)
            return missing("no lines given");
        const path = resolvePath(expected.path, repo).place?.path ?? expected.path;
        const content = repo.content(path);
        if (content === null)
            return missing("no such file");
        const count = content.split("\n").length;
        if (premise.excerpt === undefined)
            return expected.start <= count ? located({ path, start: expected.start, end: Math.min(expected.end, count) }) : missing(`the file has ${count} lines`);
        // The code those lines held when the plan was saved, wherever it is now.
        const file = repo.normalised(path);
        const target = near?.start ?? expected.start;
        const hit = (file === null ? [] : inOrder(file, [flat(premise.excerpt)], 50)).sort((a, b) => Math.abs(a[0] - target) - Math.abs(b[0] - target))[0];
        return hit === undefined ? missing("the code these lines held is not in the file now") : located({ path, start: hit[0], end: hit[1] });
    }
    /** The code at cited lines, so a later check can find where it went; blank lines carry nothing to find. */
    function excerptFor(premise, repo) {
        const expected = premise.expected;
        if (premise.kind !== "lines" || expected === undefined || expected.end - expected.start > 39)
            return null;
        const path = resolvePath(expected.path, repo).place?.path ?? expected.path;
        const excerpt = (repo.content(path) ?? "").split("\n").slice(expected.start - 1, expected.end).join("\n");
        return flat(excerpt).length >= 8 ? excerpt : null;
    }
    /** What a prompt names, resolved: each premise with how it resolved, and whether the prompt should mark it. */
    function check(premises, repo, hints) {
        return premises.flatMap((premise) => {
            const excerpt = excerptFor(premise, repo);
            const kept = excerpt === null ? premise : { ...premise, excerpt };
            const saved = resolve(kept, repo, hints);
            // A bare file name in prose ("Node.js") that the repository does not have names no file.
            if (premise.bare === true && saved.status !== "found")
                return [];
            // Only what the text states about the code as it is can be a false premise: the steps name what the change adds.
            return [{ ...kept, saved, flagged: saved.status !== "found" && kept.role === "premise" && kept.creates !== true && kept.absent !== true }];
        });
    }
    /**
     * A name one prompt says to add is no false premise in another: observed on nextra's plan (October 2026), a task
     * "builds on TASK-005's parseForwardedLast". Such a premise is not marked; it records which prompts add it.
     */
    function settle(prompts) {
        const key = (premise) => premise.kind === "symbol" ? `symbol:${lookupName(premise.text)}` : premise.kind === "path" || premise.kind === "event" || (premise.kind === "route" && premise.words === undefined) ? `${premise.kind}:${premise.text}` : null;
        const adds = new Map();
        for (const [id, premises] of prompts)
            for (const premise of premises) {
                const name = key(premise);
                if (name !== null && premise.creates === true && premise.saved.status !== "found")
                    adds.set(name, [...adds.get(name) ?? [], id]);
            }
        return new Map([...prompts].map(([id, premises]) => [id, premises.map((premise) => {
                const by = (adds.get(key(premise) ?? "") ?? []).filter((other) => other !== id);
                return premise.flagged && by.length > 0 ? { ...premise, flagged: false, addedBy: by } : premise;
            })]));
    }
    /** The same premises against the code as it is now. */
    function compare(saved, repo, hints) {
        return saved.map((premise) => {
            let now = resolve(premise, repo, hints, premise.saved.place);
            if (premise.kind === "path" && now.status === "missing" && premise.saved.status === "found") {
                const elsewhere = repo.byName().get(premise.text.slice(premise.text.lastIndexOf("/") + 1)) ?? [];
                if (elsewhere.length === 1 && elsewhere[0] !== undefined)
                    now = located({ path: elsewhere[0], start: 0, end: 0 }, "same name, another folder");
            }
            const before = premise.saved;
            const change = before.status === "found"
                ? now.status === "found" ? samePlace(before.place, now.place) ? "unchanged" : "moved" : "gone"
                : now.status === "found" ? premise.flagged ? "found_now" : "created" : premise.flagged ? "never_found" : "not_yet";
            return { premise, now, change };
        });
    }
    const samePlace = (a, b) => a === null || b === null ? a === b : a.path === b.path && a.start === b.start && a.end === b.end;
    // ---- telling a person
    const where = (place) => place === null || place.path === "" ? "" : place.start === 0 ? place.path : `${place.path}:${place.start}${place.end === place.start ? "" : `-${place.end}`}`;
    const LABEL = { path: "file", symbol: "name", route: "route", event: "event", quote: "quote", lines: "lines" };
    // Plain ASCII: the script prints to any console, and a legacy Windows code page garbles "…".
    const clip = (text, size = 90) => { const one = text.replace(/\s+/gu, " ").trim(); return one.length <= size ? one : `${one.slice(0, size - 3)}...`; };
    const describe = (premise) => premise.kind === "lines" ? premise.text : premise.kind === "route" && premise.words !== undefined ? `"${premise.text}"` : `\`${clip(premise.text).replace(/`/gu, "'")}\``;
    const fragments = (resolution) => (resolution.unmatched ?? []).map((fragment) => `\`${clip(fragment, 60).replace(/`/gu, "'")}\``).join(", ");
    /** One line for a prompt's list of what was not found. */
    function notFoundLine(premise) {
        const { saved } = premise;
        const detail = saved.status === "partial" && saved.note === REORDERED ? `${saved.note}, at ${where(saved.place)}`
            : saved.status === "partial" ? `only part of it is at ${where(saved.place)}; not found: ${fragments(saved)}`
                : premise.kind === "route" && premise.words !== undefined ? "no HTTP route or socket event in the code has that name"
                    : premise.kind === "path" ? "no such file" : premise.kind === "lines" ? saved.note ?? "not in the code"
                        : `not in the code${premise.expected === undefined ? "" : ` (the prompt places it at ${where(premise.expected)})`}`;
        return `${LABEL[premise.kind]} ${describe(premise)}: ${detail}`;
    }
    function report(id, prompt, comparisons, root, data) {
        const of = (change) => comparisons.filter((entry) => entry.change === change);
        const lines = [`Premise check for ${id} (${prompt.file}), against ${root} as it is now.`,
            `The plan was saved on ${data.savedAt.slice(0, 10)}${data.repositoryMatched ? "" : ", from files that had changed since the audit"}; this prompt names ${comparisons.length} ${comparisons.length === 1 ? "thing" : "things"} in the code.`, ""];
        const moved = of("moved");
        if (moved.length > 0)
            lines.push(`Moved since the plan was saved (${moved.length}): the same code, now at these lines.`, ...moved.map(({ premise, now }) => `  ${LABEL[premise.kind]} ${describe(premise)}: now ${where(now.place)} (was ${where(premise.saved.place)})`), "");
        const gone = of("gone");
        if (gone.length > 0)
            lines.push(`Gone since the plan was saved (${gone.length}): changed or removed, by an earlier task or another change.`, ...gone.map(({ premise, now }) => `  ${LABEL[premise.kind]} ${describe(premise)}: was ${where(premise.saved.place)}; ${now.status !== "partial" ? now.note ?? "not found now"
                : now.note === REORDERED ? `now ${now.note}, at ${where(now.place)}` : `now only part of it, at ${where(now.place)}; not found: ${fragments(now)}`}`), "");
        const never = of("never_found");
        if (never.length > 0)
            lines.push(`Never found, not when the plan was saved and not now (${never.length}):`, ...never.map(({ premise }) => `  ${notFoundLine(premise)}`), "");
        const late = [...of("found_now"), ...of("created")];
        if (late.length > 0)
            lines.push(`In the code now, not when the plan was saved (${late.length}): an earlier task or this one added it.`, ...late.map(({ premise, now }) => `  ${LABEL[premise.kind]} ${describe(premise)}: ${where(now.place)}`), "");
        const pending = of("not_yet").length;
        lines.push(`Unchanged: ${of("unchanged").length}.${pending === 0 ? "" : ` Not in the code yet, as the prompt adds ${pending === 1 ? "it" : "them"} or says ${pending === 1 ? "it is" : "they are"} missing: ${pending}.`}`, "");
        lines.push(moved.length + gone.length + never.length === 0 ? "Everything this prompt names is where the plan saw it."
            : "Work from the code as it is now: read what moved at its new lines. For what is gone or was never found, find the real code the prompt means; if there is none, the premise is false: say so in results.json's proof and in your report, and do not build on it.");
        return lines;
    }
    /** The shipped script's entry point: `node check-premises.mjs TASK-012 [--root <dir>] [--all] [--json]`. */
    function main(argv, { here, cwd, io, readData, resolvePath: absolute, print }) {
        const text = readData();
        if (text === null) {
            print(`check-premises: premises.json is missing beside this script (${here}).`);
            return 2;
        }
        const data = JSON.parse(text);
        const flags = new Set(argv.filter((argument) => argument.startsWith("--")));
        const rootAt = argv.indexOf("--root");
        const ids = argv.filter((argument, index) => !argument.startsWith("--") && (rootAt < 0 || index !== rootAt + 1));
        if (ids.length === 0 && !flags.has("--all")) {
            print("Usage: node check-premises.mjs <task id, or an unsure report's issue id> [--root <dir>] [--json], or --all for every prompt.");
            return 2;
        }
        // The working tree to check: --root, else the git working tree around the current folder (a worktree too), else the plan's own repository.
        const around = (folder) => {
            if (io.exists(folder, ".git"))
                return folder;
            const parent = absolute(folder, "..");
            return parent === folder ? absolute(here, "..", "..", "..") : around(parent);
        };
        const root = rootAt >= 0 && argv[rootAt + 1] !== undefined ? absolute(cwd, argv[rootAt + 1] ?? ".") : around(cwd);
        const keys = Object.keys(data.prompts);
        const key = (id) => {
            const upper = id.trim().toUpperCase();
            const number = /^(?:TASK-?)?0*(\d+)$/u.exec(upper)?.[1];
            return keys.find((candidate) => candidate.toUpperCase() === upper)
                ?? (number === undefined ? undefined : keys.find((candidate) => new RegExp(`^TASK-0*${number}$`, "u").test(candidate.toUpperCase())))
                ?? id;
        };
        const chosen = flags.has("--all") ? keys : ids.map(key);
        const unknown = chosen.filter((id) => data.prompts[id] === undefined);
        if (unknown.length > 0) {
            print(`check-premises: this plan has no prompt called ${unknown.join(", ")}. Use a task id such as ${keys[0] ?? "TASK-001"}.`);
            return 2;
        }
        const repo = indexRepository(root, io);
        const results = chosen.map((id) => {
            const prompt = data.prompts[id];
            return { id, prompt, comparisons: compare(prompt.premises, repo, prompt.hints.filter((path) => repo.fileSet.has(path))) };
        });
        if (flags.has("--json")) {
            print(JSON.stringify({ root, prompts: results.map(({ id, comparisons }) => ({ id, comparisons: comparisons.map(({ premise, now, change }) => ({ kind: premise.kind, text: premise.text, change, saved: premise.saved.place, now: now.place, status: now.status })) })) }, null, 2));
        }
        else if (flags.has("--all")) {
            print(`Premise check of every prompt, against ${root} as it is now.`);
            for (const { id, comparisons } of results) {
                const count = (change) => comparisons.filter((entry) => entry.change === change).length;
                print(`${id}: ${count("moved")} moved, ${count("gone")} gone, ${count("never_found")} never found, ${count("found_now") + count("created")} new, ${count("unchanged")} unchanged`);
            }
        }
        else
            for (const { id, prompt, comparisons } of results)
                for (const line of report(id, prompt, comparisons, root, data))
                    print(line);
        return results.some(({ comparisons }) => comparisons.some(({ change }) => change === "gone" || change === "never_found")) ? 1 : 0;
    }
    return { nodeIo, indexRepository, extract, resolve, check, settle, compare, notFoundLine, report, main, normalise, quotedSpans };
})();

const here = dirname(fileURLToPath(import.meta.url));
const readData = () => { try { return readFileSync(join(here, "premises.json"), "utf8"); } catch { return null; } };
process.exitCode = kit.main(process.argv.slice(2), { here, cwd: process.cwd(), io: kit.nodeIo({ execFileSync, readdirSync, readFileSync, statSync }, join), readData, resolvePath: resolve, print: (line) => process.stdout.write(`${line}\n`) });
