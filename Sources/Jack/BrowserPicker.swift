import AppKit
import JackCore
import WebKit

/// The page side of picking elements in Jack's browser: highlights what is under the mouse,
/// marks what the user picked and posts each pick to Jack. Inert until Jack calls `start()`.
enum BrowserPicker {
    static let handler = "jackPick"

    static let script = #"""
    (() => {
      if (window.__jackPicker) return;
      const accent = '#3b82f6';
      const layer = document.createElement('div');
      layer.setAttribute('data-jack-picker', '');
      layer.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483647;';
      const hover = document.createElement('div');
      hover.style.cssText = `position:fixed;pointer-events:none;border:2px solid ${accent};background:rgba(59,130,246,.12);border-radius:3px;display:none;box-sizing:border-box;`;
      const label = document.createElement('div');
      label.style.cssText = `position:fixed;pointer-events:none;background:${accent};color:#fff;font:600 11px -apple-system,system-ui,sans-serif;padding:2px 6px;border-radius:4px;display:none;white-space:nowrap;`;
      layer.append(hover, label);
      let active = false, current = null, picked = [], marks = [], hidden = false;

      const post = (body) => { try { window.webkit.messageHandlers.jackPick.postMessage(body); } catch (e) {} };

      const cssPath = (el) => {
        const parts = [];
        while (el && el.nodeType === 1 && el !== document.documentElement) {
          let part = el.tagName.toLowerCase();
          if (el.id && !/^\d/.test(el.id)) { parts.unshift(part + '#' + CSS.escape(el.id)); break; }
          const classes = [...el.classList].filter(c => !/^(css-|sc-|jsx-|svelte-|_)/.test(c) && c.length < 40).slice(0, 2);
          if (classes.length) part += '.' + classes.map(c => CSS.escape(c)).join('.');
          const parent = el.parentElement;
          if (parent) {
            const same = [...parent.children].filter(c => c.tagName === el.tagName);
            if (same.length > 1) part += `:nth-of-type(${same.indexOf(el) + 1})`;
          }
          parts.unshift(part);
          el = parent;
        }
        return parts.join(' > ');
      };

      // Development builds of React, Vue and Svelte keep the component and often its file on the node.
      const component = (el) => {
        for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
          const key = Object.keys(node).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
          if (key) {
            for (let fiber = node[key]; fiber; fiber = fiber.return) {
              const type = fiber.type;
              if (type && typeof type !== 'string') {
                const name = type.displayName || type.name || (type.render && (type.render.displayName || type.render.name));
                if (name) {
                  const src = fiber._debugSource;
                  return { component: name, source: src ? `${src.fileName}:${src.lineNumber}` : null };
                }
              }
            }
          }
          const vue = node.__vueParentComponent;
          if (vue && vue.type) return { component: vue.type.name || vue.type.__name || null, source: vue.type.__file || null };
          const svelte = node.__svelte_meta;
          if (svelte && svelte.loc) return { component: null, source: `${svelte.loc.file}:${svelte.loc.line}` };
        }
        return {};
      };

      const openingTag = (el) => {
        const html = el.outerHTML || '';
        const end = html.indexOf('>');
        const tag = end > 0 ? html.slice(0, end + 1) : `<${el.tagName.toLowerCase()}>`;
        return tag.length > 240 ? tag.slice(0, 237) + '…>' : tag;
      };

      const describe = (el) => {
        const r = el.getBoundingClientRect();
        const html = (el.outerHTML || '').replace(/\s+/g, ' ');
        const text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
        return Object.assign({
          selector: cssPath(el), tag: openingTag(el),
          text: text.length > 160 ? text.slice(0, 159) + '…' : text,
          html: html.length > 1200 ? html.slice(0, 1199) + '…' : html,
          rect: { x: r.x, y: r.y, width: r.width, height: r.height },
          url: location.href,
        }, component(el));
      };

      const place = (box, el) => {
        const r = el.getBoundingClientRect();
        box.style.left = r.x + 'px'; box.style.top = r.y + 'px';
        box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
        return r;
      };

      const drawMarks = () => {
        marks.forEach(m => m.remove());
        marks = picked.filter(el => el.isConnected).map((el, index) => {
          const box = document.createElement('div');
          box.style.cssText = `position:fixed;pointer-events:none;border:2px solid ${accent};border-radius:3px;box-sizing:border-box;`;
          box.style.display = hidden ? 'none' : 'block';
          const badge = document.createElement('div');
          badge.textContent = index + 1;
          badge.style.cssText = `position:absolute;top:-9px;left:-9px;width:18px;height:18px;border-radius:9px;background:${accent};color:#fff;font:700 10px/18px -apple-system,system-ui,sans-serif;text-align:center;`;
          box.append(badge);
          place(box, el);
          layer.append(box);
          return box;
        });
      };
      const refresh = () => {
        marks.forEach((box, i) => picked[i] && place(box, picked[i]));
        if (active && current && !hidden) showHover(current);
      };

      const showHover = (el) => {
        const r = place(hover, el);
        hover.style.display = 'block';
        const info = component(el);
        label.textContent = (info.component ? `<${info.component}> ` : '') + el.tagName.toLowerCase() + `  ${Math.round(r.width)}×${Math.round(r.height)}`;
        label.style.display = 'block';
        label.style.left = Math.max(2, r.x) + 'px';
        label.style.top = (r.y > 24 ? r.y - 22 : r.bottom + 4) + 'px';
      };

      const target = (event) => {
        const el = document.elementFromPoint(event.clientX, event.clientY);
        return el && !layer.contains(el) && el !== document.documentElement ? el : null;
      };
      const onMove = (event) => {
        const el = target(event);
        if (!el || el === current) return;
        current = el;
        showHover(el);
      };
      const swallow = (event) => {
        if (!active) return;
        event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation();
      };
      const onClick = (event) => {
        if (!active) return;
        swallow(event);
        const el = target(event);
        if (!el) return;
        const additive = event.shiftKey || event.metaKey;
        if (!additive) picked = [];
        if (!picked.includes(el)) picked.push(el);
        drawMarks();
        post(Object.assign(describe(el), { additive }));
        if (!additive) stop();
      };
      const onKey = (event) => {
        if (active && event.key === 'Escape') { swallow(event); stop(); post({ cancel: true }); }
      };

      const start = () => {
        if (!layer.isConnected) document.documentElement.append(layer);
        active = true; document.documentElement.style.cursor = 'crosshair';
      };
      const stop = () => {
        active = false; current = null;
        hover.style.display = 'none'; label.style.display = 'none';
        document.documentElement.style.cursor = '';
      };

      window.addEventListener('mousemove', (e) => active && onMove(e), true);
      ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'contextmenu'].forEach(t => window.addEventListener(t, swallow, true));
      window.addEventListener('click', onClick, true);
      window.addEventListener('keydown', onKey, true);
      window.addEventListener('scroll', refresh, true);
      window.addEventListener('resize', refresh);

      window.__jackPicker = {
        start, stop,
        remove: (index) => { picked.splice(index, 1); drawMarks(); },
        clear: () => { picked = []; drawMarks(); },
        // Hidden while Jack takes a picture of a pick, so the picture shows the element, not the marks.
        hideMarks: (value) => { hidden = value; drawMarks(); if (value) { hover.style.display = 'none'; label.style.display = 'none'; } },
      };
    })();
    """#
}

/// Receives the page's posts without the content controller keeping the session alive.
final class BrowserPickReceiver: NSObject, WKScriptMessageHandler {
    weak var session: BrowserSession?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { session?.received(body) }
    }
}
