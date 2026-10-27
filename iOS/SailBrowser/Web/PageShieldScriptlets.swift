// The eight scriptlets PageShield's rules call, written for Sailfish. Each takes the rule's arguments as strings
// and runs in the page world at document start, before the page's own scripts. A text argument is a substring, or a
// regex written /like this/; an empty one matches everything.
enum PageShieldScriptlets {
    static let helpers = """
        const pattern = text => {
          if (!text) return null;
          const regex = /^\\/(.+)\\/([dgimsuy]*)$/.exec(text);
          return regex ? new RegExp(regex[1], regex[2]) : new RegExp(text.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'));
        };
        const matches = (regex, value) => !regex || regex.test(value);
        const isObject = value => value !== null && (typeof value === 'object' || typeof value === 'function');
        // Defines the last property of a dotted chain. A link not yet there is trapped, so the definition lands when
        // the page assigns it.
        const onChain = (chain, define) => {
          const wrap = (owner, names) => {
            const [name, ...rest] = names;
            if (!rest.length) return define(owner, name);
            const current = owner[name];
            if (isObject(current)) return wrap(current, rest);
            let value = current;
            Object.defineProperty(owner, name, {
              configurable: true,
              get: () => value,
              set: next => {
                value = next;
                if (isObject(next)) wrap(next, rest);
              },
            });
          };
          wrap(window, chain.split('.'));
        };
        const whenReady = run => document.readyState === 'loading'
          ? document.addEventListener('DOMContentLoaded', run, { once: true }) : run();
        // Runs now, once the DOM is ready, and after every later change.
        const keepApplying = (apply, attributeFilter) => {
          apply();
          whenReady(() => {
            apply();
            new MutationObserver(apply).observe(document.documentElement, {
              childList: true, subtree: true, attributes: true, attributeFilter,
            });
          });
        };
        """

    static let functions: [String: String] = [
        "set-constant": """
            ([chain, name]) => {
              const noop = () => {};
              const constants = {
                undefined: undefined, false: false, true: true, null: null, '': '', emptyStr: '', yes: 'yes', no: 'no',
                '[]': [], emptyArr: [], '{}': {}, emptyObj: {}, noopFunc: noop, noopCallbackFunc: () => noop,
                trueFunc: () => true, falseFunc: () => false, throwFunc: () => { throw new Error(); },
                noopPromiseResolve: () => Promise.resolve(), noopPromiseReject: () => Promise.reject(),
              };
              let value;
              if (Object.hasOwn(constants, name)) value = constants[name];
              else if (/^-?\\d+$/.test(name) && Math.abs(Number(name)) <= 32767) value = Number(name);
              else return;
              onChain(chain, (owner, property) => Object.defineProperty(owner, property, {
                configurable: true, get: () => value, set: () => {},
              }));
            }
            """,
        "abort-on-property-read": """
            ([chain]) => {
              onChain(chain, (owner, property) => Object.defineProperty(owner, property, {
                configurable: true,
                get: () => { throw new ReferenceError(`${property} is not defined`); },
                set: () => {},
              }));
            }
            """,
        "abort-current-inline-script": """
            ([chain, search]) => {
              const text = pattern(search);
              // A script's text runs as it was, so its match is kept for every later read in it.
              const matched = new WeakMap();
              const abortInMatchingScript = () => {
                const script = document.currentScript;
                if (!(script instanceof HTMLScriptElement) || script.src) return;
                if (!matched.has(script)) matched.set(script, matches(text, script.textContent));
                if (matched.get(script)) throw new ReferenceError(`${chain} is not defined`);
              };
              onChain(chain, (owner, property) => {
                let value = owner[property];
                Object.defineProperty(owner, property, {
                  configurable: true,
                  get: () => { abortInMatchingScript(); return value; },
                  set: next => { abortInMatchingScript(); value = next; },
                });
              });
            }
            """,
        "json-prune": """
            ([remove = '', required = '']) => {
              // A path is dot separated; [] steps into every item of an array and * into every key.
              const paths = text => text.split(' ').filter(Boolean).map(path => path.split('.'));
              const removals = paths(remove), requirements = paths(required);
              const has = (value, names) => {
                if (!names.length) return true;
                if (!isObject(value)) return false;
                const [name, ...rest] = names;
                if (name === '[]' || name === '*') return Object.values(value).some(item => has(item, rest));
                return Object.hasOwn(value, name) && has(value[name], rest);
              };
              const prune = (value, names) => {
                if (!isObject(value)) return;
                const [name, ...rest] = names;
                if (name === '[]' || name === '*') {
                  for (const key of Object.keys(value)) {
                    if (rest.length) prune(value[key], rest); else delete value[key];
                  }
                } else if (rest.length) {
                  prune(value[name], rest);
                } else {
                  delete value[name];
                }
              };
              const pruned = value => {
                if (isObject(value) && requirements.every(names => has(value, names))) {
                  removals.forEach(names => prune(value, names));
                }
                return value;
              };
              const parse = JSON.parse;
              JSON.parse = function (...args) { return pruned(parse.apply(this, args)); };
              const json = Response.prototype.json;
              Response.prototype.json = function (...args) { return json.apply(this, args).then(pruned); };
            }
            """,
        "remove-attr": """
            ([names, selector = '']) => {
              const attributes = names.split('|').filter(Boolean);
              const target = selector || attributes.map(name => `[${CSS.escape(name)}]`).join(', ');
              keepApplying(() => {
                for (const element of document.querySelectorAll(target)) {
                  attributes.forEach(name => element.removeAttribute(name));
                }
              }, attributes);
            }
            """,
        "remove-class": """
            ([names, selector = '']) => {
              const classes = names.split('|').filter(Boolean);
              const target = selector || classes.map(name => `.${CSS.escape(name)}`).join(', ');
              keepApplying(() => {
                for (const element of document.querySelectorAll(target)) {
                  if (classes.some(name => element.classList.contains(name))) element.classList.remove(...classes);
                }
              }, ['class']);
            }
            """,
        "prevent-addEventListener": """
            ([type = '', listener = '']) => {
              const types = pattern(type), listeners = pattern(listener);
              const add = EventTarget.prototype.addEventListener;
              EventTarget.prototype.addEventListener = function (eventType, handler, ...rest) {
                const source = String(typeof handler?.handleEvent === 'function' ? handler.handleEvent : handler);
                if (matches(types, String(eventType)) && matches(listeners, source)) return;
                return add.call(this, eventType, handler, ...rest);
              };
            }
            """,
        // A leading ! inverts either argument.
        "prevent-setTimeout": """
            ([callback = '', delay = '']) => {
              const negated = text => text.startsWith('!');
              const callbacks = pattern(callback.replace(/^!/, ''));
              const wanted = delay.replace(/^!/, '');
              const setTimeout = window.setTimeout;
              window.setTimeout = function (handler, timeout, ...rest) {
                const callbackMatches = matches(callbacks, String(handler)) !== negated(callback);
                const delayMatches = !wanted || (Number(timeout) === Number(wanted)) !== negated(delay);
                if (callbackMatches && delayMatches) return 0;
                return setTimeout.call(this, handler, timeout, ...rest);
              };
            }
            """,
    ]
}
