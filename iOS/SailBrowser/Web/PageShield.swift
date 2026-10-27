import Foundation
import WebKit

// What WebKit's rule lists cannot run: CSS beyond display:none, procedural selectors, scriptlets and the cookie wall
// unlock. The rules are per domain, so each controller gets scripts built for the host it shows. Cosmetic work runs in
// an isolated world; scriptlets patch page globals, so they run in the page's.
final class PageShield {
    nonisolated struct Rules: Codable, Sendable {
        var css: String?
        var procedural: [String]?
        var scriptlets: [[String]]?
    }

    static let world = WKContentWorld.world(name: "PageShield")
    // Players embedded in other sites' pages. Their frames get their own host's scriptlets on any page.
    static let embedHosts: Set = [
        "youtube.com", "www.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com", "youtubekids.com",
    ]

    private let rules: [BlockingCategory: [String: Rules]]
    private let embedHosts: [String]

    private init(_ rules: [BlockingCategory: [String: Rules]], embedHosts: Set<String>) {
        self.rules = rules
        self.embedHosts = embedHosts.sorted()
    }

    static func bundled(in bundle: Bundle, embedHosts: Set<String> = embedHosts) async throws -> PageShield {
        let lists = BlockingCategory.allCases.map { ($0, bundle.url(forResource: $0.rawValue, withExtension: "json")!) }
        return PageShield(try await load(lists), embedHosts: embedHosts)
    }

    @concurrent private static func load(_ lists: [(BlockingCategory, URL)]) async throws
        -> [BlockingCategory: [String: Rules]]
    {
        let decoder = JSONDecoder()
        var rules: [BlockingCategory: [String: Rules]] = [:]
        for (category, url) in lists {
            rules[category] = try decoder.decode([String: Rules].self, from: Data(contentsOf: url))
        }
        return rules
    }

    // The keys a host's rules sit under: generic, each parent domain, and "name.*" for a name under a one or two
    // label suffix, which is how lists write "any country domain".
    static func keys(for host: String) -> [String] {
        var keys = [""]
        var labels = host.split(separator: ".")
        while !labels.isEmpty {
            keys.append(labels.joined(separator: "."))
            if (2...3).contains(labels.count) {
                keys.append("\(labels[0]).*")
            }
            labels.removeFirst()
        }
        return keys
    }

    private func matched(_ host: String, _ categories: Set<BlockingCategory>) -> [Rules] {
        let keys = Self.keys(for: host)
        return BlockingCategory.allCases.filter(categories.contains).flatMap { category in
            keys.compactMap { rules[category]![$0] }
        }
    }

    func scripts(for host: String, categories: Set<BlockingCategory>) -> [WKUserScript] {
        let shown = matched(host, categories)
        let css = shown.compactMap(\.css).joined(separator: "\n")
        let procedural = shown.flatMap { $0.procedural ?? [] }
        let unlocksCookieWalls = categories.contains(.cookieBanners)
        var scripts: [WKUserScript] = []
        if !css.isEmpty || !procedural.isEmpty || unlocksCookieWalls {
            let recheck = Int(Theme.Blocking.cosmeticRecheck / .milliseconds(1))
            let watch = Int(Theme.Blocking.cookieWallWatch / .milliseconds(1))
            let source = """
                (() => {
                const host = \(Self.literal(host)), css = \(Self.literal(css)), procedural = \(Self.literal(procedural));
                const unlocksCookieWalls = \(unlocksCookieWalls), recheck = \(recheck), watch = \(watch);
                \(Self.cosmetic)
                })();
                """
            scripts.append(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.world))
        }
        // The shown host's calls, then each embed host's, each run only in a frame on that host.
        let groups = ([host] + embedHosts.filter { $0 != host }).compactMap { frameHost in
            let calls = matched(frameHost, categories).flatMap { $0.scriptlets ?? [] }
            return calls.isEmpty ? nil : ScriptletGroup(host: frameHost, calls: calls)
        }
        if !groups.isEmpty {
            let functions = Set(groups.flatMap { $0.calls.map { $0[0] } }).sorted()
                .map { "\(Self.literal($0)): \(PageShieldScriptlets.functions[$0]!)" }
            let source = """
                (() => {
                const group = \(Self.literal(groups)).find(group => group.host === location.hostname);
                if (!group) return;
                \(PageShieldScriptlets.helpers)
                const scriptlets = {
                \(functions.joined(separator: ",\n"))
                };
                for (const [name, ...args] of group.calls) {
                  try { scriptlets[name](args); } catch {}
                }
                })();
                """
            scripts.append(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        return scripts
    }

    private struct ScriptletGroup: Encodable {
        let host: String
        let calls: [[String]]
    }

    private static func literal(_ value: some Encodable) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    // Procedural selectors are a native part and steps: :has-text(text or /regex/), :upward(n or selector), and :has()
    // around either. A step that follows a native part with a combinator searches below each match.
    private static let cosmetic = """
          const hide = element => element.style.setProperty('display', 'none', 'important');
          // Longest durations, and most DOM work, of one run of each, in this world's global, which the page cannot
          // see. Work counts each DOM call and each element a query returns, so it is the same on every load of a page.
          const timings = window.sailShieldTimings = { pass: 0, recheck: 0, check: 0 };
          const work = window.sailShieldWork = { pass: 0, recheck: 0, check: 0, checksBeforeRender: 0 };
          let done = 0;
          const did = (count = 1) => { done += count; };
          const query = (root, selector) => {
            const found = [...root.querySelectorAll(selector)];
            did(1 + found.length);
            return found;
          };
          const timed = (key, run) => {
            done = 0;
            const start = performance.now();
            run();
            timings[key] = Math.max(timings[key], performance.now() - start);
            work[key] = Math.max(work[key], done);
          };
          const ready = run => document.readyState === 'loading'
            ? document.addEventListener('DOMContentLoaded', run, { once: true }) : run();

          if (location.hostname === host && css) {
            const sheet = new CSSStyleSheet();
            sheet.replaceSync(css);
            document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
          }

          if (location.hostname === host && procedural.length) {
            const closing = (text, open) => {
              let depth = 0, quote = null;
              for (let i = open; i < text.length; i++) {
                const c = text[i];
                if (c === '\\\\') { i++; continue; }
                if (quote) { if (c === quote) quote = null; }
                else if (c === '"' || c === "'") quote = c;
                else if (c === '(' || c === '[') depth++;
                else if ((c === ')' || c === ']') && --depth === 0) return i;
              }
              return text.length;
            };
            const matcher = text => {
              const regex = /^\\/(.+)\\/([imsu]*)$/.exec(text);
              if (!regex) return value => value.includes(text);
              const pattern = new RegExp(regex[1], regex[2]);
              return value => pattern.test(value);
            };
            const compile = selector => {
              const steps = [], pseudo = /:(has-text|upward|has)\\(/g;
              let from = 0, match;
              while ((match = pseudo.exec(selector))) {
                const end = closing(selector, pseudo.lastIndex - 1);
                const name = match[1], argument = selector.slice(pseudo.lastIndex, end);
                pseudo.lastIndex = end + 1;
                if (name === 'has' && !/:(has-text|upward)\\(/.test(argument)) continue;
                steps.push(['native', selector.slice(from, match.index)]);
                steps.push([name, name === 'has' ? compile(argument)
                  : name === 'upward' ? (/^\\d+$/.test(argument) ? Number(argument) : argument) : matcher(argument)]);
                from = end + 1;
              }
              steps.push(['native', selector.slice(from)]);
              return steps.filter(([kind, value], index) => kind !== 'native' || index === 0 || value.trim());
            };
            const combinator = /^\\s*[>+~]|^\\s/, sibling = /^\\s*[+~]/;
            // Siblings sit beside an element, so a + or ~ step queries from its parent.
            const below = (element, value) => {
              if (!sibling.test(value)) return query(element, ':scope' + value);
              const parent = element.parentElement;
              if (!parent) return [];
              const place = [...parent.children].indexOf(element) + 1;
              did(parent.children.length);
              return query(parent, `:scope > :nth-child(${place})${value}`);
            };
            const ancestor = (element, levels) => {
              for (let i = 0; i < levels && element; i++) element = element.parentElement;
              did(levels);
              return element;
            };
            const run = (steps, root) => {
              let found = null;
              for (const [kind, value] of steps) {
                if (kind === 'native') {
                  const combined = combinator.test(value);
                  if (found === null) {
                    found = combined ? below(root, value) : query(root, value.trim() || '*');
                  } else if (combined) {
                    found = found.flatMap(element => below(element, value));
                  } else {
                    did(found.length);
                    found = found.filter(element => element.matches(value));
                  }
                } else if (kind === 'has-text') {
                  did(found.length);
                  found = found.filter(element => value(element.textContent));
                } else if (kind === 'upward') {
                  if (typeof value !== 'number') did(found.length);
                  found = found.map(element => typeof value === 'number'
                    ? ancestor(element, value) : element.parentElement?.closest(value)).filter(Boolean);
                } else {
                  found = found.filter(element => run(value, element).length > 0);
                }
              }
              return found;
            };
            const compiled = [];
            for (const selector of procedural) {
              try { compiled.push(compile(selector)); } catch {}
            }
            const pass = () => {
              for (const steps of compiled) {
                try { run(steps, document).forEach(hide); } catch {}
              }
            };
            let scheduled = false;
            const schedule = () => {
              if (scheduled) return;
              scheduled = true;
              setTimeout(() => { scheduled = false; timed('recheck', pass); }, recheck);
            };
            ready(() => {
              timed('pass', pass);
              new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
            });
          }

          // A consent manager hidden by the cookie list can leave html or body unscrollable and a backdrop over the
          // page. Once one is hidden, its lock and backdrop go too, and a documented reject button is clicked; accept
          // never is. A banner only named like one counts when it is fixed. The check reads styles after a rendering
          // update, when they are already computed, and watches html and body only until a window after load and
          // the first unlock, so the site's own later locks, a menu or a modal, stay.
          if (unlocksCookieWalls && window === window.top) {
            const rootIDs = ['onetrust-consent-sdk', 'didomi-host', 'qc-cmp2-container', 'usercentrics-root',
              'usercentrics-cmp-ui', 'truste-consent-track', 'consent_blackbar', 'CybotCookiebotDialog'];
            // One test per child of body: id then class, for the prefix and class roots and for banners named like one.
            const rootPattern = /^sp_message_container_|(^|\\s)(qc-cmp2-container|truste_box_overlay)(\\s|$)/;
            const namePattern = /cookie|consent|gdpr/i;
            const backdrops = '.onetrust-pc-dark-filter, .didomi-popup-backdrop, .sp_veil, .truste_overlay, '
              + '.truste_box_overlay, #CybotCookiebotDialogBodyUnderlay, .qc-cmp2-container';
            const rejects = '#onetrust-reject-all-handler, #didomi-notice-disagree-button, '
              + '#CybotCookiebotDialogBodyButtonDecline';
            let rejected = false, unlocked = false, loaded = document.readyState === 'complete';
            let observer = null, stop = null, queued = false;
            const watchFromNow = () => {
              clearTimeout(stop);
              stop = setTimeout(() => observer?.disconnect(), watch);
            };
            // A check reads computed styles. Run before a rendering update, that forces a style pass, about 9 ms on a
            // heavy page, so each check counts whether an animation frame came before it.
            let rendered = false;
            const check = () => {
              if (!rendered) work.checksBeforeRender++;
              rendered = false;
              const cmps = rootIDs.map(id => document.getElementById(id)).filter(Boolean), named = [];
              did(rootIDs.length + document.body.children.length);
              for (const child of document.body.children) {
                const names = child.id + ' ' + (child.getAttribute('class') ?? '');
                if (rootPattern.test(names)) {
                  cmps.push(child);
                } else if (namePattern.test(names)) {
                  named.push(child);
                }
              }
              did(cmps.length + 2 * named.length);
              const hiddenBanner = cmps.length ? cmps.some(element => !element.checkVisibility())
                : named.some(element => !element.checkVisibility() && getComputedStyle(element).position === 'fixed');
              if (!hiddenBanner) return;
              if (cmps.length && !rejected) {
                const button = document.querySelector(rejects);
                did();
                if (button) {
                  rejected = true;
                  button.click();
                }
              }
              // WebKit can report a fixed body's overflow as not hidden, so either sign of a lock clears both.
              did(2);
              for (const element of [document.documentElement, document.body]) {
                const style = getComputedStyle(element);
                if (style.overflowY !== 'hidden' && style.position !== 'fixed') continue;
                element.style.setProperty('overflow-y', 'visible', 'important');
                if (style.position === 'fixed') {
                  element.style.setProperty('position', 'static', 'important');
                  element.style.setProperty('top', 'auto', 'important');
                }
              }
              query(document, backdrops).forEach(hide);
              if (!unlocked && loaded) watchFromNow();
              unlocked = true;
            };
            const checkAfterRender = () => {
              if (queued) return;
              queued = true;
              requestAnimationFrame(() => {
                rendered = true;
                setTimeout(() => {
                  queued = false;
                  timed('check', check);
                });
              });
            };
            ready(() => {
              if (!document.body) return;
              checkAfterRender();
              observer = new MutationObserver(checkAfterRender);
              for (const element of [document.documentElement, document.body]) {
                observer.observe(element, { attributes: true, attributeFilter: ['style', 'class'] });
              }
              observer.observe(document.body, { childList: true });
              if (loaded) {
                watchFromNow();
              } else {
                window.addEventListener('load', () => { loaded = true; watchFromNow(); }, { once: true });
              }
            });
          }
        """
}
