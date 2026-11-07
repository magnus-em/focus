import Foundation
import WebKit

/// Turns a saved page into clean article HTML, Reader-style. The page is parsed by an
/// offscreen WKWebView with the page's own JavaScript and subresources off; a small
/// readability scorer (paragraph text density, minus link density and nav/comment-ish
/// class names) picks the article body, which is then stripped to plain markup.
@MainActor
final class ArticleExtractor: NSObject, WKNavigationDelegate {
    static let shared = ArticleExtractor()

    struct Article {
        var title: String
        var byline: String
        var siteName: String
        var excerpt: String
        var image: String
        var html: String
        var words: Int
    }

    private var webView: WKWebView?
    private var waiting: CheckedContinuation<Void, Never>?
    private var currentNav: ObjectIdentifier?
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var rules: WKContentRuleList?

    func extract(html: String, baseURL: URL) async -> Article? {
        if busy { await withCheckedContinuation { queue.append($0) } }
        busy = true
        defer {
            busy = false
            if !queue.isEmpty { queue.removeFirst().resume() }
        }
        let web = await view()
        let loaded = Task { @MainActor in
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiting = c
                currentNav = web.loadHTMLString(html, baseURL: baseURL).map(ObjectIdentifier.init)
            }
        }
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            finishLoad()
        }
        await loaded.value
        timeout.cancel()
        guard let raw = try? await web.callAsyncJavaScript(Self.script, contentWorld: .defaultClient) as? String,
              let data = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = o["html"] as? String, !body.isEmpty else { return nil }
        return Article(title: o["title"] as? String ?? "", byline: o["byline"] as? String ?? "",
                       siteName: o["siteName"] as? String ?? "", excerpt: o["excerpt"] as? String ?? "",
                       image: o["image"] as? String ?? "", html: body, words: o["words"] as? Int ?? 0)
    }

    private func view() async -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        if rules == nil {
            let json = #"[{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","raw","svg-document","popup"]},"action":{"type":"block"}}]"#
            rules = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "focus-extract", encodedContentRuleList: json)
        }
        if let rules { config.userContentController.add(rules) }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 2000), configuration: config)
        web.navigationDelegate = self
        webView = web
        return web
    }

    private func finishLoad(_ nav: ObjectIdentifier? = nil) {
        if let nav, nav != currentNav { return }
        waiting?.resume()
        waiting = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in self.finishLoad(id) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in self.finishLoad(id) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in self.finishLoad(id) }
    }

    // MARK: Plain-string helpers for HTML that's already clean (Readwise's html_content)

    static func stripScripts(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "iframe", "noscript"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<figure>\\s*<p class=\"rw-outer-content\">[\\s\\S]*?</figure>", with: "", options: [.regularExpression, .caseInsensitive])
        return s.replacingOccurrences(of: "\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*')", with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Whether `b` contains the first words of `a`'s text (the same article, not its comments).
    static func sameOpening(_ a: String, _ b: String) -> Bool {
        let words = { (h: String) -> [Substring] in
            h.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&[a-z#0-9]+;", with: " ", options: .regularExpression)
                .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        }
        let opening = words(a).prefix(12).joined(separator: " ")
        guard !opening.isEmpty else { return false }
        return words(b).prefix(600).joined(separator: " ").contains(opening)
    }

    static func wordCount(_ html: String) -> Int {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace }).count
    }

    private static let script = #"""
    const doc = document;
    const meta = (...names) => {
      for (const n of names) {
        const el = doc.querySelector(`meta[property="${n}"], meta[name="${n}"]`);
        const v = el && el.getAttribute('content');
        if (v && v.trim()) return v.trim();
      }
      return '';
    };
    let ld = {};
    for (const s of doc.querySelectorAll('script[type="application/ld+json"]')) {
      try {
        let j = JSON.parse(s.textContent);
        if (j['@graph']) j = j['@graph'];
        for (const o of (Array.isArray(j) ? j : [j])) {
          if (o && /Article|Posting|Report|Blog/.test([].concat(o['@type'] || []).join(' '))) { ld = o; break; }
        }
      } catch {}
    }
    const ldAuthor = () => {
      const a = [].concat(ld.author || []).map((x) => (typeof x === 'string' ? x : x && x.name)).filter(Boolean);
      return a.join(', ');
    };
    const title = (meta('og:title', 'twitter:title') || ld.headline || doc.title || '').trim();
    let byline = meta('author', 'article:author', 'parsely-author', 'sailthru.author', 'dc.creator') || ldAuthor();
    if (/^https?:/.test(byline)) byline = ldAuthor();
    if (!byline) {
      const b = doc.querySelector('[rel="author"], .byline, .author, [itemprop="author"]');
      if (b) byline = b.textContent.trim().replace(/^by\s+/i, '').slice(0, 120);
    }
    const siteName = meta('og:site_name', 'application-name');
    const excerpt = meta('og:description', 'description', 'twitter:description');
    const image = meta('og:image', 'twitter:image');

    const NEG = /comment|footer|footnote-back|masthead|sidebar|sponsor|promo|related|recommend|share|social|subscribe|newsletter|signup|banner|advert|\bad[s-]|cookie|consent|modal|popup|nav|menu|breadcrumb|outbrain|taboola|paywall|toolbar|skip/i;
    const POS = /article|body|content|entry|main|page|post|text|blog|story|prose/i;
    const STRIP = 'script,style,noscript,iframe,form,button,input,select,textarea,nav,aside,footer,svg,canvas,object,embed,template,dialog,link,meta';
    for (const el of doc.querySelectorAll(STRIP)) el.remove();

    const classScore = (el) => {
      const s = `${el.className && el.className.baseVal === undefined ? el.className : ''} ${el.id || ''}`;
      let n = 0;
      if (NEG.test(s) && !POS.test(s)) n -= 25;
      if (POS.test(s)) n += 25;
      return n;
    };
    const textLen = (el) => (el.textContent || '').replace(/\s+/g, ' ').trim().length;
    const linkDensity = (el) => {
      const t = textLen(el) || 1;
      let l = 0;
      for (const a of el.querySelectorAll('a')) l += textLen(a);
      return l / t;
    };

    const scores = new Map();
    const add = (el, n) => {
      if (!el || el === doc.documentElement) return;
      if (!scores.has(el)) scores.set(el, classScore(el) + ({ ARTICLE: 10, MAIN: 8, SECTION: 3, DIV: 5 }[el.tagName] || 0));
      scores.set(el, scores.get(el) + n);
    };
    // A long comment thread outweighs a short post (scottaaronson.blog, 11/7), so its text never votes.
    const COMMENTS = /(^|[\s_-])(comments?|commentlist|comment-list|comments-area|respond|replies|discussion|disqus)([\s_-]|$)/i;
    const inComments = (el) => {
      for (let a = el; a && a !== doc.body; a = a.parentElement) {
        if (COMMENTS.test(`${typeof a.className === 'string' ? a.className : ''} ${a.id || ''}`)) return true;
      }
      return false;
    };
    for (const p of doc.body ? doc.body.querySelectorAll('p, pre, td, blockquote, li') : []) {
      const t = (p.textContent || '').trim();
      if (t.length < 25 || inComments(p)) continue;
      if (p.tagName === 'LI' && t.length < 80) continue;
      const n = 1 + t.split(/[,，]/).length + Math.min(Math.floor(t.length / 100), 3);
      add(p.parentElement, n);
      add(p.parentElement && p.parentElement.parentElement, n / 2);
      const g = p.parentElement && p.parentElement.parentElement && p.parentElement.parentElement.parentElement;
      add(g, n / 6);
    }
    let best = null, bestScore = 0;
    for (const [el, s] of scores) {
      const adj = s * (1 - linkDensity(el));
      if (adj > bestScore) { best = el; bestScore = adj; }
    }
    const article = doc.querySelector('article');
    if (!best || (article && textLen(article) > textLen(best) * 1.4 && linkDensity(article) < 0.3)) best = article || best;
    if (!best) best = doc.querySelector('main') || doc.body;
    if (!best) return JSON.stringify({});

    const root = best.cloneNode(true);
    // Captions and image blocks keep their meaning once class names are stripped.
    const retag = (el, tag) => {
      const n = doc.createElement(tag);
      while (el.firstChild) n.appendChild(el.firstChild);
      el.replaceWith(n);
      return n;
    };
    const CAPTION = /(^|[\s_-])(thecap|caption|captiontext|wp-caption-text|figcaption|image-credit|imgcap-text)([\s_-]|$)/i;
    const FIGURE = /(^|[\s_-])(imgcap|wp-caption|image-block|figure|media-image|article-image)([\s_-]|$)/i;
    const cls = (el) => (typeof el.className === 'string' ? el.className : '');
    for (const el of [...root.querySelectorAll('div, p, span')]) {
      if (CAPTION.test(cls(el)) && !el.querySelector('img') && textLen(el) > 0 && textLen(el) < 1600) retag(el, 'figcaption');
    }
    for (const el of [...root.querySelectorAll('div, span, p')]) {
      if (el.querySelector('img') && (FIGURE.test(cls(el)) || el.querySelector(':scope > figcaption')) && textLen(el) < 2400) retag(el, 'figure');
    }
    for (const el of root.querySelectorAll('*')) {
      if (!el.isConnected) continue;
      const tag = el.tagName;
      if (/^(DIV|SECTION|UL|OL|TABLE|HEADER|ASIDE|SPAN|P)$/.test(tag)) {
        const s = `${typeof el.className === 'string' ? el.className : ''} ${el.id || ''}`;
        const t = textLen(el);
        const imgs = el.querySelectorAll('img').length;
        if ((NEG.test(s) && !POS.test(s) && t < 2000) || (el.hidden || el.getAttribute('aria-hidden') === 'true')) { el.remove(); continue; }
        if (tag !== 'SPAN' && tag !== 'P' && t < 200 && imgs === 0 && linkDensity(el) > 0.5) { el.remove(); continue; }
        if (tag === 'HEADER' && t < 400) { el.remove(); continue; }
      }
    }
    for (const img of root.querySelectorAll('img')) {
      const src = img.getAttribute('data-src') || img.getAttribute('data-lazy-src') || img.getAttribute('data-original') || img.getAttribute('src');
      if (!src || src.startsWith('data:image/gif') || /pixel|spacer|1x1/.test(src)) { img.remove(); continue; }
      try { img.setAttribute('src', new URL(src, doc.baseURI).href); } catch { img.remove(); continue; }
      // Percentage widths are layout intent (two images side by side); pixel sizes aren't kept.
      const w = (img.getAttribute('width') || '').trim();
      const pct = /%$/.test(w) ? w : /%$/.test(img.style.maxWidth) ? img.style.maxWidth : /%$/.test(img.style.width) ? img.style.width : '';
      if (pct && parseFloat(pct) > 0 && parseFloat(pct) < 100) img.setAttribute('width', pct); else img.removeAttribute('width');
      const set = img.getAttribute('data-srcset') || img.getAttribute('srcset');
      if (set) img.setAttribute('srcset', set.split(',').map((part) => {
        const [u, d] = part.trim().split(/\s+/);
        try { return new URL(u, doc.baseURI).href + (d ? ' ' + d : ''); } catch { return ''; }
      }).filter(Boolean).join(', '));
    }
    for (const pic of root.querySelectorAll('picture source')) pic.remove();
    for (const a of root.querySelectorAll('a[href]')) {
      try { a.setAttribute('href', new URL(a.getAttribute('href'), doc.baseURI).href); } catch {}
    }
    const KEEP = new Set(['href', 'src', 'srcset', 'alt', 'title', 'colspan', 'rowspan', 'start', 'datetime', 'width']);
    for (const el of [root, ...root.querySelectorAll('*')]) {
      for (const attr of [...el.attributes]) if (!KEEP.has(attr.name)) el.removeAttribute(attr.name);
      if (el.tagName === 'A' && /^javascript:/i.test(el.getAttribute('href') || '')) el.removeAttribute('href');
    }
    for (const h of root.querySelectorAll('h1')) {
      if (h.textContent.trim() && title.includes(h.textContent.trim().slice(0, 40))) { h.remove(); break; }
    }
    for (const el of [...root.querySelectorAll('div, span, section, p')].reverse()) {
      if (!el.textContent.trim() && !el.querySelector('img, video, picture, br, hr')) el.remove();
    }
    const text = root.textContent.replace(/\s+/g, ' ').trim();
    return JSON.stringify({
      title, byline, siteName, excerpt: excerpt.slice(0, 400), image,
      html: root.innerHTML, words: text ? text.split(' ').length : 0,
    });
    """#
}
