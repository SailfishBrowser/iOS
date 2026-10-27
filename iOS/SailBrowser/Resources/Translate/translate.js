// Runs in the "translate" content world, so the page cannot see or change it. Each document gets its own copy.
globalThis.sailTranslate ??= (() => {
  const skipped = 'script, style, noscript, code, pre, textarea, input, [translate="no"], [contenteditable]:not([contenteditable="false"])';
  let originals = new Map();
  // The source language once the page shows its translation; it survives a trip through the back-forward cache.
  let translatedFrom = null;

  const accepts = node =>
    node.nodeValue.trim() && !node.parentElement.closest(skipped) && node.parentElement.checkVisibility();
  // The page's translatable text nodes, in document order.
  function* textNodes() {
    if (!document.body) {
      return;
    }
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: node => (accepts(node) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT),
    });
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      yield node;
    }
  }
  return {
    // Up to limit characters (Theme.Translate.sampleLength), gathered node by node so a huge page is never
    // serialised whole.
    sample(limit) {
      let text = '';
      for (const node of textNodes()) {
        if (text.length >= limit) {
          break;
        }
        text += (text ? ' ' : '') + node.nodeValue.trim();
      }
      return { lang: document.documentElement.lang ?? '', text: text.slice(0, limit), from: translatedFrom };
    },
    collect() {
      this.restore();
      const texts = [];
      for (const node of textNodes()) {
        const id = String(originals.size);
        originals.set(id, { node, text: node.nodeValue });
        texts.push({ id, text: node.nodeValue.trim() });
      }
      return texts;
    },
    apply(results) {
      for (const { id, text } of results) {
        const original = originals.get(id);
        const [lead] = original.text.match(/^\s*/);
        const [trail] = original.text.match(/\s*$/);
        original.node.nodeValue = lead + text + trail;
      }
    },
    // Only a page that holds collected text is marked: a mark that reaches a newer document leaves it alone.
    mark(from) {
      translatedFrom = originals.size ? from : null;
      return from;
    },
    restore() {
      for (const { node, text } of originals.values()) {
        node.nodeValue = text;
      }
      originals = new Map();
      translatedFrom = null;
    },
  };
})();
