import SwiftUI
import WebKit

/// An article pulled out of a page by Readability: what Reader sets in type.
struct Article: Equatable {
    var url: URL
    var title: String
    var byline: String?
    var siteName: String?
    /// Readability's cleaned markup. Scripts are gone and the reader page's policy blocks the rest.
    var html: String
    var wordCount: Int
    var lang: String?
    var dir: String?
}

/// Reader for one tab. Runtime only: a relaunch shows the page, and Reader is a tap away.
struct ReaderSession: Equatable {
    /// The page Reader was opened on. Going anywhere else closes Reader.
    var url: URL?
    var article: Article?
    var failed = false
    /// How far through, 0 to 1. Kept so the article opens where you were when the posture changes.
    var progress: Double = 0
    /// Where the paged layouts are, counted from zero, and how many pages there are.
    var page = 0
    var pages = 1

    var isReady: Bool { article != nil }

    var wordsLeft: Int {
        guard let article else { return 0 }
        return Int((Double(article.wordCount) * (1 - progress)).rounded())
    }

    /// "6 min left", at an easy 230 words a minute. The last page says it's done.
    var timeLeft: String {
        if progress >= 0.995 { return "Finished" }
        let minutes = max(1, Int((Double(wordsLeft) / 230).rounded(.up)))
        return "\(minutes) min left"
    }
}

/// Readability, run in its own script world so the page's scripts can't reach it or trip over it.
@MainActor
enum ReaderExtractor {
    private static func source(_ name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static let readability = source("Readability")
    private static let readerable = source("Readability-readerable")
    private static let world = WKContentWorld.world(name: "spine-reader-extract")

    /// Readability's quick check: is there an article here worth offering Reader for?
    static func isReaderable(_ webView: WKWebView) async -> Bool {
        guard let readerable else { return false }
        let body = readerable + "\n;return isProbablyReaderable(document, { minContentLength: 140, minScore: 20 });"
        let result = try? await webView.callAsyncJavaScript(body, contentWorld: world)
        return (result as? Bool) ?? false
    }

    static func extract(from webView: WKWebView) async -> Article? {
        guard let readability, let url = webView.url else { return nil }
        let body = readability + """

        ;var copy = document.cloneNode(true);
        // Edit links, maintenance banners, footnote markers and navigation boxes are page furniture.
        // Sections a phone site folds away are still the article. Open them first.
        copy.querySelectorAll('.collapsible-block, [hidden="until-found"], details').forEach(function (node) {
          node.removeAttribute('hidden');
          if (node.tagName === 'DETAILS') { node.setAttribute('open', ''); }
          if (node.style) { node.style.removeProperty('display'); }
        });
        copy.querySelectorAll('.mw-editsection, .ambox, .mbox-small, .navbox, .noprint, .metadata, sup.reference, .reference, [role=navigation], .hatnote, .shortdescription').forEach(function (node) { node.remove(); });
        var parsed = new Readability(copy, { charThreshold: 300 }).parse();
        if (!parsed || !parsed.content) { return null; }
        var text = (parsed.textContent || '').trim();
        return {
          title: parsed.title || document.title || '',
          byline: parsed.byline || '',
          siteName: parsed.siteName || '',
          content: parsed.content,
          words: text ? text.split(/\\s+/).length : 0,
          lang: parsed.lang || document.documentElement.lang || '',
          dir: parsed.dir || ''
        };
        """
        guard let result = try? await webView.callAsyncJavaScript(body, contentWorld: world) as? [String: Any],
              let html = result["content"] as? String else { return nil }
        func text(_ key: String) -> String? {
            (result[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        let words = (result["words"] as? Int) ?? (result["words"] as? NSNumber)?.intValue ?? 0
        guard words >= 60 else { return nil }
        return Article(
            url: url, title: text("title") ?? url.host() ?? "", byline: text("byline"), siteName: text("siteName"),
            html: html, wordCount: words, lang: text("lang"), dir: text("dir")
        )
    }
}

// MARK: - Tone

/// The paper Reader prints on. Match follows the browser's day or night.
enum ReaderTone: Equatable {
    case day, sepia, night, black

    init(_ preferences: ReaderPreferences, isDark: Bool) {
        switch preferences.theme {
        case .match: self = isDark ? (preferences.trueBlack ? .black : .night) : .day
        case .day: self = .day
        case .sepia: self = .sepia
        case .night: self = preferences.trueBlack ? .black : .night
        }
    }

    var isDark: Bool { self == .night || self == .black }

    var background: UInt32 {
        switch self {
        case .day: 0xFEFDFA
        case .sepia: 0xF4ECDD
        case .night: 0x1E1A16
        case .black: 0x000000
        }
    }

    var text: UInt32 {
        switch self {
        case .day: 0x221D18
        case .sepia: 0x3B2F22
        case .night: 0xEAE7E2
        case .black: 0xDAD6D0
        }
    }

    var secondary: UInt32 {
        switch self {
        case .day: 0x605A54
        case .sepia: 0x6B5C4B
        case .night: 0xA8A49E
        case .black: 0x9A958F
        }
    }

    var line: UInt32 {
        switch self {
        case .day: 0xDEDAD3
        case .sepia: 0xE0D3BE
        case .night: 0x342F2B
        case .black: 0x26221F
        }
    }

    /// Chips and code blocks sit on this.
    var sunken: UInt32 {
        switch self {
        case .day: 0xECE9E2
        case .sepia: 0xEADFCB
        case .night: 0x292420
        case .black: 0x171411
        }
    }

    /// Links are verdigris: the one action color.
    var link: UInt32 {
        switch self {
        case .day: 0x217969
        case .sepia: 0x1D6A5C
        case .night, .black: 0x75BBAB
        }
    }

    /// A book's spread: each page darkens toward the gutter, and the gutter sinks deepest.
    /// Day takes the Paper file's values; the others follow the same fall-off.
    var spread: (page: UInt32, toward: UInt32, edge: UInt32, gutter: UInt32, gutterDeep: UInt32) {
        switch self {
        case .day: (0xFAF8F3, 0xF6F2EA, 0xEDE7DD, 0xE6DFD3, 0xD9D1C3)
        case .sepia: (0xF4ECDD, 0xF0E6D4, 0xE6D9C2, 0xDDCEB4, 0xD0BFA2)
        case .night: (0x1E1A16, 0x1B1814, 0x16130F, 0x12100D, 0x0C0A08)
        case .black: (0x000000, 0x000000, 0x050404, 0x0A0908, 0x121010)
        }
    }

    var desk: UInt32 {
        switch self {
        case .day: 0xF9F6F0
        case .sepia: 0xF1E8D7
        case .night: 0x1A1612
        case .black: 0x000000
        }
    }
}

// MARK: - The reader page

/// How the article flows: down one scrolling column, or across pages, one or two at a time.
enum ReaderFlow: Equatable {
    case scroll
    /// Columns of `width`, `gap` apart, `perSpread` on screen at once.
    case paged(width: CGFloat, gap: CGFloat, perSpread: Int)

    var isPaged: Bool { if case .paged = self { true } else { false } }
}

enum ReaderDocument {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func css(_ hex: UInt32) -> String { String(format: "#%06X", hex) }

    /// The CSS variables a change of tone, size or face rewrites in place.
    static func variables(tone: ReaderTone, preferences: ReaderPreferences) -> [String: String] {
        let size = Double(preferences.size)
        // 18/29 by day; dark pages get a point more air, 18/30.
        let lead = (size * (tone.isDark ? 30 : 29) / 18).rounded()
        let serif = "ui-serif, 'New York', Georgia, serif"
        let sans = "-apple-system, system-ui, 'SF Pro Text', sans-serif"
        return [
            "--bg": css(tone.background),
            "--text": css(tone.text),
            "--sec": css(tone.secondary),
            "--line": css(tone.line),
            "--sunken": css(tone.sunken),
            "--link": css(tone.link),
            "--size": "\(Int(size))px",
            "--lead": "\(Int(lead))px",
            "--face": preferences.face == .serif ? serif : sans,
            "--title-face": serif,
            "--ui-face": sans,
        ]
    }

    static func html(article: Article, tone: ReaderTone, preferences: ReaderPreferences, flow: ReaderFlow, start: Double) -> String {
        let vars = variables(tone: tone, preferences: preferences)
            .map { "\($0.key): \($0.value);" }
            .sorted()
            .joined(separator: " ")
        let kicker = (article.siteName ?? article.url.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "")
        let byline = article.byline.map { "<p class=\"byline\">\(escape($0))</p>" } ?? ""
        let lang = article.lang.map { " lang=\"\(escape($0))\"" } ?? ""
        let dir = article.dir.map { " dir=\"\(escape($0))\"" } ?? ""
        var data = "data-words=\"\(article.wordCount)\" data-start=\"\(start)\""
        var mode = "scroll"
        if case let .paged(width, gap, perSpread) = flow {
            mode = "paged"
            data += " data-width=\"\(width)\" data-gap=\"\(gap)\" data-per-spread=\"\(perSpread)\""
        }
        return """
        <!doctype html>
        <html\(lang)\(dir)>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data: blob:; media-src *; style-src 'unsafe-inline'; font-src *">
        <style>:root { \(vars) }
        \(stylesheet)</style>
        </head>
        <body class="\(mode)" \(data)>
        <div id="book"><article>
        <p class="kicker">\(escape(kicker))</p>
        <h1 class="title">\(escape(article.title))</h1>
        \(byline)
        <div class="content">\(article.html)</div>
        </article></div>
        </body>
        </html>
        """
    }

    private static let stylesheet = """
    html { -webkit-text-size-adjust: 100%; background: var(--bg); }
    body { margin: 0; color: var(--text); background: var(--bg); font-family: var(--face); font-size: var(--size);
      line-height: var(--lead); font-kerning: normal; text-rendering: optimizeLegibility; -webkit-hyphens: manual; hyphens: manual;
      overflow-wrap: break-word; }
    article { max-width: 62ch; margin: 0 auto; padding: var(--top, 76px) 32px 120px; }
    .kicker { font-family: var(--ui-face); font-size: 11px; line-height: 14px; font-weight: 600; letter-spacing: 0.08em;
      text-transform: uppercase; color: var(--sec); margin: 0 0 16px; -webkit-hyphens: none; }
    .title { font-family: var(--title-face); font-size: 32px; line-height: 38px; font-weight: 600; letter-spacing: -0.005em;
      margin: 0 0 16px; -webkit-hyphens: none; hyphens: none; text-wrap: balance; }
    .byline { font-family: var(--ui-face); font-size: 13px; line-height: 18px; color: var(--sec); margin: -4px 0 20px; }
    .content > :first-child, .content > div > :first-child { margin-top: 0; }
    p { margin: 0 0 16px; }
    h2, h3, h4, h5, h6 { font-family: var(--title-face); font-weight: 600; margin: 28px 0 12px; -webkit-hyphens: none; break-after: avoid; }
    h2 { font-size: 22px; line-height: 28px; }
    h3 { font-size: 19px; line-height: 25px; }
    h4, h5, h6 { font-size: 17px; line-height: 22px; }
    a { color: var(--link); text-decoration-thickness: 1px; text-underline-offset: 3px; }
    img, video, svg, picture { display: block; max-width: 100%; height: auto; border-radius: 6px; margin: 20px auto 8px; }
    figure { margin: 20px 0; }
    figure img { margin-top: 0; }
    figcaption, .caption, .wp-caption-text { font-size: 13px; line-height: 18px; font-style: italic; color: var(--sec); margin-top: 8px; }
    blockquote { margin: 20px 0; padding-left: 18px; border-left: 2px solid var(--line); font-style: italic; }
    ul, ol { padding-left: 1.3em; margin: 0 0 16px; }
    li { margin-bottom: 6px; }
    hr { border: 0; border-top: 1px solid var(--line); margin: 28px 0; }
    pre, code { font-family: ui-monospace, 'SF Mono', Menlo, monospace; font-size: 0.82em; }
    pre { background: var(--sunken); padding: 12px 14px; border-radius: 8px; overflow-x: auto; line-height: 1.5; }
    :not(pre) > code { background: var(--sunken); padding: 1px 5px; border-radius: 4px; }
    table { width: 100%; border-collapse: collapse; font-family: var(--ui-face); font-size: 14px; line-height: 20px; margin: 20px 0; }
    td, th { border-bottom: 1px solid var(--line); padding: 6px 8px; text-align: left; vertical-align: top; }
    iframe, object, embed, form, input, button { display: none; }

    /* Paged: a fixed-height block whose columns run off to the right, turned a spread at a time. */
    html:has(body.paged) { background: transparent; }
    body.paged { background: transparent; height: 100vh; overflow: hidden; }
    body.paged #book { height: 100vh; column-fill: auto; transition: transform 0.42s cubic-bezier(0.22, 0.8, 0.24, 1); }
    body.paged article { max-width: none; margin: 0; padding: 0; }
    body.paged img, body.paged video, body.paged svg { max-height: 58vh; width: auto; object-fit: contain; break-inside: avoid; }
    body.paged figure, body.paged blockquote, body.paged pre, body.paged table, body.paged li { break-inside: avoid; }
    body.paged pre { white-space: pre-wrap; }
    @media (prefers-reduced-motion: reduce) { body.paged #book { transition: opacity 0.18s ease-out; } }
    """

    /// Turns pages, reports progress, and takes new type without losing your place.
    static let script = """
    (function () {
      var body = document.body;
      if (!body || window.spineReader) { return; }
      var book = document.getElementById('book');
      var words = +body.dataset.words || 0;
      var paged = body.classList.contains('paged');
      var width = 0, gap = 0, per = 1, spread = 0, pages = 1;
      var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

      function post(message) { try { webkit.messageHandlers.reader.postMessage(message); } catch (e) {} }

      function spreads() { return Math.max(1, Math.ceil(pages / per)); }
      function step() { return per * (width + gap); }

      function measure() {
        if (!paged) { return; }
        book.style.width = (per * width + (per - 1) * gap) + 'px';
        book.style.columnCount = per;
        book.style.columnGap = gap + 'px';
        var total = book.scrollWidth;
        pages = Math.max(1, Math.round((total + gap) / (width + gap)));
      }

      function progress() {
        if (paged) { return spreads() <= 1 ? 1 : spread / (spreads() - 1); }
        var range = document.documentElement.scrollHeight - window.innerHeight;
        return range <= 0 ? 1 : Math.min(1, Math.max(0, window.scrollY / range));
      }

      function report() {
        post({ kind: 'state', progress: progress(), page: spread * per, pages: pages });
      }

      function show(index, animated) {
        spread = Math.min(Math.max(0, index), spreads() - 1);
        var offset = -spread * step();
        if (!animated) {
          var previous = book.style.transition;
          book.style.transition = 'none';
          book.style.transform = 'translateX(' + offset + 'px)';
          book.offsetHeight;
          book.style.transition = previous;
        } else if (reduce) {
          book.style.opacity = '0';
          setTimeout(function () { book.style.transform = 'translateX(' + offset + 'px)'; book.style.opacity = '1'; }, 120);
        } else {
          book.style.transform = 'translateX(' + offset + 'px)';
        }
        report();
      }

      function goTo(fraction) {
        if (paged) {
          show(Math.round(fraction * (spreads() - 1)), false);
        } else {
          var range = document.documentElement.scrollHeight - window.innerHeight;
          window.scrollTo(0, Math.max(0, range * fraction));
          report();
        }
      }

      function layout(w, g, n) {
        var keep = progress();
        width = w; gap = g; per = n;
        measure();
        goTo(keep);
      }

      window.spineReader = {
        next: function () { if (spread < spreads() - 1) { show(spread + 1, true); } else { post({ kind: 'edge', end: true }); } },
        previous: function () { if (spread > 0) { show(spread - 1, true); } else { post({ kind: 'edge', end: false }); } },
        goTo: goTo,
        layout: layout,
        restyle: function (vars) {
          var keep = progress();
          for (var key in vars) { document.documentElement.style.setProperty(key, vars[key]); }
          requestAnimationFrame(function () { measure(); goTo(keep); });
        }
      };

      if (paged) {
        width = +body.dataset.width; gap = +body.dataset.gap; per = +body.dataset.perSpread || 1;
        // Swipe or tap the outer third of a page to turn. Taps on links still follow them.
        var startX = 0, startY = 0;
        addEventListener('touchstart', function (e) { var t = e.touches[0]; startX = t.clientX; startY = t.clientY; }, { passive: true });
        addEventListener('touchend', function (e) {
          var t = e.changedTouches[0];
          var dx = t.clientX - startX, dy = t.clientY - startY;
          if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy) * 1.3) {
            if (dx < 0) { window.spineReader.next(); } else { window.spineReader.previous(); }
            return;
          }
          if (Math.abs(dx) > 10 || Math.abs(dy) > 10 || (e.target.closest && e.target.closest('a'))) { return; }
          var x = t.clientX;
          var lastPageStart = (per - 1) * (width + gap);
          if (x < width / 3) { window.spineReader.previous(); }
          else if (x > lastPageStart + width * 2 / 3) { window.spineReader.next(); }
        }, { passive: true });
        addEventListener('keydown', function (e) {
          if (e.key === 'ArrowRight' || e.key === ' ' || e.key === 'PageDown') { window.spineReader.next(); e.preventDefault(); }
          if (e.key === 'ArrowLeft' || e.key === 'PageUp') { window.spineReader.previous(); e.preventDefault(); }
        });
      } else {
        var queued = false;
        addEventListener('scroll', function () {
          if (queued) { return; }
          queued = true;
          requestAnimationFrame(function () { queued = false; report(); });
        }, { passive: true });
      }

      // The page can arrive before its window has its final size, and postures change it.
      // Measure again whenever the size changes, keeping your place.
      var lastSize = innerWidth + 'x' + innerHeight;
      addEventListener('resize', function () {
        var size = innerWidth + 'x' + innerHeight;
        if (size === lastSize) { return; }
        lastSize = size;
        var keep = progress();
        requestAnimationFrame(function () { measure(); goTo(keep); });
      });

      function settle() { measure(); goTo(+body.dataset.start || 0); }
      // Images change the length as they arrive, so the count settles again once they do.
      if (document.readyState === 'complete') { settle(); } else { addEventListener('load', settle); }
      settle();
      var images = document.images;
      for (var i = 0; i < images.length; i++) {
        if (!images[i].complete) { images[i].addEventListener('load', function () { var keep = progress(); measure(); goTo(keep); }); }
      }
      post({ kind: 'ready', words: words });
    })();
    """
}
