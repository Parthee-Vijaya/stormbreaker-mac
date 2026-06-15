import SwiftUI
import WebKit
import ForgeKit

/// WKWebView wrapped for SwiftUI. JS bridge: (1) posts window.onerror /
/// console.error / unhandledrejection for self-correction, and (2) a "select
/// mode" that highlights elements on hover and posts the clicked element for
/// visual editing. Bump `reloadToken` to reload.
struct WebView: NSViewRepresentable {
    let url: URL?
    var reloadToken: Int = 0
    var selectMode: Bool = false
    let onRuntimeIssue: (RuntimeIssue) -> Void
    let onElementSelected: (String, String, String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRuntimeIssue: onRuntimeIssue, onElementSelected: onElementSelected)
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "forge")
        // Main frame only: a generated app that embeds a hostile <iframe> must not
        // be able to inject the bridge or post messages to Swift.
        controller.addUserScript(WKUserScript(
            source: Self.bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        #if DEBUG
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url else { return }
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            context.coordinator.retryCount = 0
            webView.load(URLRequest(url: url))
        } else if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
        if context.coordinator.selectMode != selectMode {
            context.coordinator.selectMode = selectMode
            webView.evaluateJavaScript("window.__forgeSetSelect && window.__forgeSetSelect(\(selectMode))")
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "forge")
        controller.removeAllUserScripts()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onRuntimeIssue: (RuntimeIssue) -> Void
        private let onElementSelected: (String, String, String, String) -> Void
        weak var webView: WKWebView?
        var loadedURL: URL?
        var retryCount = 0
        var lastReloadToken = 0
        var selectMode = false

        init(onRuntimeIssue: @escaping (RuntimeIssue) -> Void,
             onElementSelected: @escaping (String, String, String, String) -> Void) {
            self.onRuntimeIssue = onRuntimeIssue
            self.onElementSelected = onElementSelected
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == "forge", message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any] else { return }
            let kind = body["kind"] as? String ?? ""
            if kind == "select" {
                onElementSelected(
                    body["tag"] as? String ?? "element",
                    body["text"] as? String ?? "",
                    body["className"] as? String ?? "",
                    body["selector"] as? String ?? "")
                return
            }
            let issueKind = RuntimeIssue.Kind(rawValue: kind) ?? .consoleError
            onRuntimeIssue(RuntimeIssue(
                kind: issueKind,
                message: body["message"] as? String ?? "Unknown error",
                source: body["source"] as? String,
                line: body["line"] as? Int))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            guard retryCount < 4, let url = loadedURL else { return }
            retryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak webView] in
                webView?.load(URLRequest(url: url))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            retryCount = 0
            // Re-apply select mode after a (re)load re-injects the bridge.
            webView.evaluateJavaScript("window.__forgeSetSelect && window.__forgeSetSelect(\(selectMode))")
        }
    }

    static let bridgeJS = """
    (function () {
      function post(payload) {
        try { window.webkit.messageHandlers.forge.postMessage(payload); } catch (e) {}
      }
      // Turn any thrown value / console.error argument into a useful string for
      // the self-correction loop — never the useless "[object Event]" /
      // "[object Object]". Prefers an Error's stack, then its message, then a
      // readable Event description, then JSON, then String().
      function describe(v) {
        if (v == null) return String(v);
        if (typeof v === 'string') return v;
        if (typeof v !== 'object' && typeof v !== 'function') return String(v);
        if (v.stack || v.message) return String(v.stack || v.message);
        if (typeof Event !== 'undefined' && v instanceof Event) {
          var t = v.target || {};
          var where = t.src || t.href || (t.tagName ? t.tagName.toLowerCase() : '');
          return 'Event(' + v.type + ')' + (where ? ' on ' + where : '');
        }
        try { var s = JSON.stringify(v); if (s && s !== '{}') return s; } catch (_) {}
        return String(v);
      }
      window.addEventListener('error', function (e) {
        var msg = (e.error && (e.error.stack || e.error.message)) || e.message || describe(e);
        post({ kind: 'onerror',
               message: msg,
               source: e.filename || null,
               line: e.lineno || null });
      }, true);
      window.addEventListener('unhandledrejection', function (e) {
        var r = e.reason;
        var msg = (r && (r.stack || r.message)) || describe(r);
        post({ kind: 'unhandledRejection', message: msg, source: null, line: null });
      });
      var original = console.error;
      console.error = function () {
        try {
          post({ kind: 'consoleError',
                 message: Array.prototype.map.call(arguments, describe).join(' '),
                 source: null, line: null });
        } catch (_) {}
        return original.apply(console, arguments);
      };

      // Visual select mode
      var selecting = false, hovered = null;
      function classOf(el) { return (typeof el.className === 'string') ? el.className : ''; }
      function selectorOf(el) {
        if (!el || !el.tagName || el === document.body) return 'body';
        var i = 0, sib = el;
        while ((sib = sib.previousElementSibling) != null) i++;
        var parent = el.parentElement ? selectorOf(el.parentElement) : '';
        return parent + '>' + el.tagName.toLowerCase() + ':nth-child(' + (i + 1) + ')';
      }
      document.addEventListener('mouseover', function (e) {
        if (!selecting) return;
        if (hovered) hovered.style.outline = '';
        hovered = e.target;
        e.target.style.outline = '2px solid #2563eb';
        e.target.style.outlineOffset = '-2px';
      }, true);
      document.addEventListener('mouseout', function (e) { if (selecting) e.target.style.outline = ''; }, true);
      document.addEventListener('click', function (e) {
        if (!selecting) return;
        e.preventDefault(); e.stopPropagation();
        var el = e.target;
        post({ kind: 'select', tag: el.tagName.toLowerCase(),
               text: (el.innerText || '').trim().slice(0, 80),
               className: classOf(el), selector: selectorOf(el) });
      }, true);
      window.__forgeSetSelect = function (v) {
        selecting = !!v;
        document.documentElement.style.cursor = v ? 'crosshair' : '';
        if (!v && hovered) { hovered.style.outline = ''; hovered = null; }
      };
    })();
    """
}
