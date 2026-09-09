import SwiftUI
import WebKit

#if os(macOS)
    typealias PlatformViewRepresentable = NSViewRepresentable
#elseif os(iOS)
    typealias PlatformViewRepresentable = UIViewRepresentable
#endif

#if !os(visionOS)
    @available(macOS 11.0, iOS 14.0, *)
    public struct MarkdownWebView: PlatformViewRepresentable {
        var markdownContent: String
        let customStylesheet: String?
        let linkActivationHandler: ((URL) -> Void)?
        let renderedContentHandler: ((String) -> Void)?
        let enableBenchmarking: Bool
        let fontSize: CGFloat
        let loggingTag = String(
            (0..<5).map { _ in
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()!
            })

        // Shared process pool
        static let sharedProcessPool: WKProcessPool = WKProcessPool()

        // Precompiled HTML with all resources inlined
        static let precompiledHTML: String = {
            #if os(macOS)
                let defaultStylesheetFileName = "default-macOS"
            #elseif os(iOS)
                let defaultStylesheetFileName = "default-iOS"
            #endif

            guard
                let templateFileURL = Bundle.module.url(
                    forResource: "template", withExtension: "html"),
                let templateString = try? String(contentsOf: templateFileURL)
            else {
                print("Failed to load template.html")
                return ""
            }

            guard
                let scriptFileURL = Bundle.module.url(
                    forResource: "markdown-it-bundle", withExtension: "js"),
                let script = try? String(contentsOf: scriptFileURL)
            else {
                print("Failed to load markdown-it-bundle.js")
                return ""
            }

            guard
                let defaultStylesheetFileURL = Bundle.module.url(
                    forResource: defaultStylesheetFileName, withExtension: "css"),
                let defaultStylesheet = try? String(contentsOf: defaultStylesheetFileURL)
            else {
                print("Failed to load \(defaultStylesheetFileName).css")
                return ""
            }

            guard
                let githubMarkdownURL = Bundle.module.url(
                    forResource: "github-markdown", withExtension: "css"),
                let githubMarkdownCSS = try? String(contentsOf: githubMarkdownURL)
            else {
                print("Failed to load github-markdown.css")
                return ""
            }

            guard
                let katexURL = Bundle.module.url(forResource: "katex", withExtension: "css"),
                let katexCSS = try? String(contentsOf: katexURL)
            else {
                print("Failed to load katex.css")
                return ""
            }

            guard
                let texmathURL = Bundle.module.url(forResource: "texmath", withExtension: "css"),
                let texmathCSS = try? String(contentsOf: texmathURL)
            else {
                print("Failed to load texmath.css")
                return ""
            }

            let htmlString =
                templateString
                .replacingOccurrences(of: "PLACEHOLDER_SCRIPT", with: script)
                .replacingOccurrences(
                    of: "PLACEHOLDER_STYLESHEET",
                    with: defaultStylesheet + "\n" + "\n" + githubMarkdownCSS
                        + "\n" + katexCSS + "\n" + texmathCSS
                )
                .replacingOccurrences(of: "CUSTOM_STYLE_PLACEHOLDER", with: "")

            return htmlString
        }()

        public init(
            _ markdownContent: String,
            customStylesheet: String? = nil,
            fontSize: CGFloat = 15,
            enableBenchmarking: Bool = false
        ) {
            self.markdownContent = markdownContent
            self.customStylesheet = customStylesheet
            self.fontSize = fontSize
            self.enableBenchmarking = enableBenchmarking
            linkActivationHandler = nil
            renderedContentHandler = nil
        }

        init(
            _ markdownContent: String,
            customStylesheet: String?,
            fontSize: CGFloat = 15,
            linkActivationHandler: ((URL) -> Void)?,
            renderedContentHandler: ((String) -> Void)?,
            enableBenchmarking: Bool
        ) {
            self.markdownContent = markdownContent
            self.customStylesheet = customStylesheet
            self.fontSize = fontSize
            self.linkActivationHandler = linkActivationHandler
            self.renderedContentHandler = renderedContentHandler
            self.enableBenchmarking = enableBenchmarking
        }

        public func makeCoordinator() -> Coordinator { .init(parent: self) }

        #if os(macOS)
            public func makeNSView(context: Context) -> CustomWebView {
                context.coordinator.platformView
            }
        #elseif os(iOS)
            public func makeUIView(context: Context) -> CustomWebView {
                let view = context.coordinator.platformView
                view.fontSize = fontSize // Set the initial font size
                return view
            }
        #endif

        func updatePlatformView(_ platformView: CustomWebView, context _: Context) {
            guard !platformView.isLoading else { return }
            let js = """
                    document.getElementById('markdown-rendered').style.fontSize = '\(fontSize)px';
                    """
            platformView.evaluateJavaScript(js, completionHandler: nil)
            
            // Only update content if it changed
            if platformView.lastMarkdownContent != markdownContent {
                platformView.updateMarkdownContent(markdownContent)
            }
        }

        #if os(macOS)
            public func updateNSView(_ nsView: CustomWebView, context: Context) {
                updatePlatformView(nsView, context: context)
            }
        #elseif os(iOS)
            public func updateUIView(_ uiView: CustomWebView, context: Context) {
                context.coordinator.parent = self
                uiView.fontSize = fontSize  // Use uiView instead of platformView
                uiView.updateMarkdownContent(markdownContent)
            }
        #endif

        public func onLinkActivation(_ linkActivationHandler: @escaping (URL) -> Void) -> Self {
            .init(
                markdownContent, customStylesheet: customStylesheet,
                linkActivationHandler: linkActivationHandler,
                renderedContentHandler: renderedContentHandler,
                enableBenchmarking: enableBenchmarking)
        }

        public func onRendered(_ renderedContentHandler: @escaping (String) -> Void) -> Self {
            .init(
                markdownContent, customStylesheet: customStylesheet,
                linkActivationHandler: linkActivationHandler,
                renderedContentHandler: renderedContentHandler,
                enableBenchmarking: enableBenchmarking)
        }

        public class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            var parent: MarkdownWebView
            let platformView: CustomWebView
            var startTime: CFAbsoluteTime?
            private var timerStartTimes: [String: Double] = [:]
            private var swiftBenchmarks: [String: CFAbsoluteTime] = [:]

            init(parent: MarkdownWebView) {
                self.parent = parent
                let config = WKWebViewConfiguration()
                config.suppressesIncrementalRendering = true
                config.processPool = MarkdownWebView.sharedProcessPool
                let userContentController = WKUserContentController()
                config.userContentController = userContentController
                platformView = CustomWebView(frame: .zero, configuration: config)
                super.init()

                if parent.enableBenchmarking {
                    startTime = CFAbsoluteTimeGetCurrent()
                    swiftBenchmarks["Coordinator Init Start"] = startTime!
                    print(
                        "Swift Benchmark - \(parent.loggingTag) - Coordinator Init Start: \(startTime!)s"
                    )
                }

                platformView.navigationDelegate = self

                #if DEBUG && os(iOS)
                    if #available(iOS 16.4, *) {
                        self.platformView.isInspectable = true
                    }
                #endif

                platformView.setContentHuggingPriority(.required, for: .vertical)

                #if os(iOS)
                    platformView.scrollView.isScrollEnabled = false
                    platformView.enableDoubleTapCopy()
                #endif

                #if os(macOS)
                    platformView.setValue(false, forKey: "drawsBackground")
                #elseif os(iOS)
                    platformView.isOpaque = false
                #endif

                userContentController.add(self, name: "sizeChangeHandler")
                userContentController.add(self, name: "renderedContentHandler")
                userContentController.add(self, name: "copyToPasteboard")
                if parent.enableBenchmarking {
                    userContentController.add(self, name: "consoleLogHandler")
                }

                let htmlString = MarkdownWebView.precompiledHTML.replacingOccurrences(
                    of: "CUSTOM_STYLE_PLACEHOLDER",
                    with: parent.customStylesheet ?? ""
                )

                if parent.enableBenchmarking {
                    swiftBenchmarks["Before HTML Load"] = CFAbsoluteTimeGetCurrent()
                    print(
                        "Swift Benchmark - \(parent.loggingTag) - Before HTML Load: \(swiftBenchmarks["Before HTML Load"]! - swiftBenchmarks["Coordinator Init Start"]!)s"
                    )
                }

                platformView.loadHTMLString(htmlString, baseURL: nil)

                if parent.enableBenchmarking {
                    swiftBenchmarks["After HTML Load"] = CFAbsoluteTimeGetCurrent()
                    print(
                        "Swift Benchmark - \(parent.loggingTag) - HTML Load Duration: \(swiftBenchmarks["After HTML Load"]! - swiftBenchmarks["Before HTML Load"]!)s"
                    )
                }
            }

            public func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                if parent.enableBenchmarking {
                    swiftBenchmarks["WebView Did Finish"] = CFAbsoluteTimeGetCurrent()
                    print(
                        "Swift Benchmark - \(parent.loggingTag) - WebView Load Duration: \(swiftBenchmarks["WebView Did Finish"]! - swiftBenchmarks["After HTML Load"]!)s"
                    )
                }
                // Render the newest content: chunks that arrived while the HTML
                // was still loading were only stored, never executed.
                let view = webView as! CustomWebView
                view.updateMarkdownContent(view.hasPendingContent ? view.lastMarkdownContent : parent.markdownContent)
            }

            public func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction)
                async -> WKNavigationActionPolicy
            {
                if navigationAction.navigationType == .linkActivated {
                    guard let url = navigationAction.request.url else { return .cancel }

                    if let linkActivationHandler = parent.linkActivationHandler {
                        linkActivationHandler(url)
                    } else {
                        #if os(macOS)
                            NSWorkspace.shared.open(url)
                        #elseif os(iOS)
                            DispatchQueue.main.async {
                                Task { await UIApplication.shared.open(url) }
                            }
                        #endif
                    }
                    return .cancel
                } else {
                    return .allow
                }
            }

            public func userContentController(
                _: WKUserContentController, didReceive message: WKScriptMessage
            ) {
                switch message.name {
                case "sizeChangeHandler":
                    guard let contentHeight = message.body as? CGFloat,
                        platformView.contentHeight != contentHeight
                    else { return }
                    platformView.contentHeight = contentHeight
                    platformView.invalidateIntrinsicContentSize()

                case "renderedContentHandler":
                    if parent.enableBenchmarking, let startTime = startTime {
                        let endTime = CFAbsoluteTimeGetCurrent()
                        let renderTime = endTime - startTime
                        print(
                            "Swift Benchmark - \(parent.loggingTag) - Total Markdown Rendering Time: \(renderTime)s"
                        )
                        self.startTime = nil
                    }
                    guard let renderedContentHandler = parent.renderedContentHandler,
                        let renderedContentBase64Encoded = message.body as? String,
                        let renderedContentBase64EncodedData: Data = .init(
                            base64Encoded: renderedContentBase64Encoded),
                        let renderedContent = String(
                            data: renderedContentBase64EncodedData, encoding: .utf8)
                    else { return }
                    renderedContentHandler(renderedContent)

                case "copyToPasteboard":
                    guard let base64EncodedString = message.body as? String else { return }
                    base64EncodedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        .copyToPasteboard()

                case "consoleLogHandler" where parent.enableBenchmarking:
                    if let body = message.body as? [String: Any],
                        let type = body["type"] as? String,
                        let label = body["label"] as? String,
                        let timestamp = body["timestamp"] as? Double
                    {
                        switch type {
                        case "time":
                            timerStartTimes[label] = timestamp
                        case "timeEnd":
                            if let startTime = timerStartTimes[label] {
                                let duration = timestamp - startTime
                                print(
                                    "JS Benchmark - \(parent.loggingTag) - \(label) Completed: \(duration)ms"
                                )
                                timerStartTimes.removeValue(forKey: label)
                            } else {
                                print(
                                    "JS Benchmark - \(parent.loggingTag) - \(label) Ended: \(timestamp)ms (no start time)"
                                )
                            }
                        default:
                            break
                        }
                    }

                default:
                    return
                }
            }
        }

        public class CustomWebView: WKWebView {
            var contentHeight: CGFloat = 0
            var fontSize: CGFloat = 15
            var lastMarkdownContent: String = ""
            var hasPendingContent = false
            override public var intrinsicContentSize: CGSize {
                .init(width: super.intrinsicContentSize.width, height: contentHeight)
            }

            #if os(macOS)
                override public func scrollWheel(with event: NSEvent) {
                    super.scrollWheel(with: event)
                    nextResponder?.scrollWheel(with: event)
                }

                override public func willOpenMenu(_ menu: NSMenu, with _: NSEvent) {
                    menu.items.removeAll { $0.identifier == .init("WKMenuItemIdentifierReload") }
                }

                override public func keyDown(with event: NSEvent) {
                    nextResponder?.keyDown(with: event)
                }

                override public func keyUp(with event: NSEvent) {
                    nextResponder?.keyUp(with: event)
                }

                override public func flagsChanged(with event: NSEvent) {
                    nextResponder?.flagsChanged(with: event)
                }
            #elseif os(iOS)
                // Keeps the double-tap → Copy menu handler alive (iOS 16+).
                private var doubleTapCopyHandler: AnyObject?

                func enableDoubleTapCopy() {
                    guard #available(iOS 16.0, *), doubleTapCopyHandler == nil else { return }
                    doubleTapCopyHandler = DoubleTapCopyHandler(webView: self)
                }

                override public func pressesBegan(
                    _ presses: Set<UIPress>, with event: UIPressesEvent?
                ) {
                    super.pressesBegan(presses, with: event)
                    next?.pressesBegan(presses, with: event)
                }

                override public func pressesEnded(
                    _ presses: Set<UIPress>, with event: UIPressesEvent?
                ) {
                    super.pressesEnded(presses, with: event)
                    next?.pressesEnded(presses, with: event)
                }

                override public func pressesChanged(
                    _ presses: Set<UIPress>, with event: UIPressesEvent?
                ) {
                    super.pressesChanged(presses, with: event)
                    next?.pressesChanged(presses, with: event)
                }
            #endif

            func updateMarkdownContent(_ markdownContent: String) {
                lastMarkdownContent = markdownContent
                // Page still loading: window.updateWithMarkdownContentBase64Encoded is undefined,
                // so defer until didFinish instead of silently dropping this update.
                if isLoading {
                    hasPendingContent = true
                    return
                }
                hasPendingContent = false
                guard
                    let markdownContentBase64Encoded = markdownContent.data(using: .utf8)?
                        .base64EncodedString()
                else { return }
                
                // First update the font size
                let js = """
                document.getElementById('markdown-rendered').style.fontSize = '\(fontSize)px';
                window.updateWithMarkdownContentBase64Encoded(`\(markdownContentBase64Encoded)`);
                """
                
                callAsyncJavaScript(
                    js,
                    in: nil, in: .page, completionHandler: nil)
            }
        }
    }

    #if os(iOS)
        /// Double tap selects the word under the finger and shows an edit menu with a
        /// single Copy action that writes HTML + RTF + plain text to the pasteboard.
        @available(iOS 16.0, *)
        final class DoubleTapCopyHandler: NSObject, UIGestureRecognizerDelegate,
            UIEditMenuInteractionDelegate
        {
            private weak var webView: WKWebView?
            private var interaction: UIEditMenuInteraction?
            private var selectedText = ""
            private var selectedHTML = ""

            init(webView: WKWebView) {
                self.webView = webView
                super.init()

                let tap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
                tap.numberOfTapsRequired = 2
                tap.cancelsTouchesInView = false
                tap.delaysTouchesEnded = false
                tap.delegate = self
                webView.addGestureRecognizer(tap)

                let interaction = UIEditMenuInteraction(delegate: self)
                webView.addInteraction(interaction)
                self.interaction = interaction
            }

            func gestureRecognizer(
                _: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
            ) -> Bool { true }

            @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
                guard let webView, gesture.state == .ended else { return }
                let point = gesture.location(in: webView)
                // Select the word at the tap point and return its text + HTML fragment.
                let js = """
                    (function () {
                      const range = document.caretRangeFromPoint(\(point.x), \(point.y));
                      if (!range) { return null; }
                      if (range.expand) { range.expand('word'); }
                      const sel = window.getSelection();
                      sel.removeAllRanges();
                      sel.addRange(range);
                      const text = sel.toString();
                      if (!text.trim()) { sel.removeAllRanges(); return null; }
                      const div = document.createElement('div');
                      div.appendChild(range.cloneContents());
                      return { text: text, html: div.innerHTML };
                    })();
                    """
                webView.evaluateJavaScript(js) { [weak self] result, _ in
                    guard let self, let dict = result as? [String: Any],
                        let text = dict["text"] as? String
                    else { return }
                    self.selectedText = text
                    self.selectedHTML = dict["html"] as? String ?? ""
                    self.interaction?.presentEditMenu(
                        with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
                }
            }

            func editMenuInteraction(
                _: UIEditMenuInteraction, menuFor _: UIEditMenuConfiguration,
                suggestedActions _: [UIMenuElement]
            ) -> UIMenu? {
                let title = Bundle(for: UIApplication.self)
                    .localizedString(forKey: "Copy", value: "Copy", table: nil)
                let copy = UIAction(title: title, image: UIImage(systemName: "doc.on.doc")) {
                    [weak self] _ in self?.copySelection()
                }
                return UIMenu(children: [copy])
            }

            private func copySelection() {
                var item: [String: Any] = ["public.utf8-plain-text": selectedText]
                if !selectedHTML.isEmpty, let htmlData = selectedHTML.data(using: .utf8) {
                    item["public.html"] = htmlData
                    // RTF for apps that don't read HTML (Pages, Mail composer, etc.).
                    if let attributed = try? NSAttributedString(
                        data: htmlData,
                        options: [
                            .documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue,
                        ],
                        documentAttributes: nil),
                        let rtf = try? attributed.data(
                            from: NSRange(location: 0, length: attributed.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                    {
                        item["public.rtf"] = rtf
                    }
                }
                UIPasteboard.general.setItems([item])
            }
        }
    #endif
#endif

extension String {
    func copyToPasteboard() {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self, forType: .string)
        #else
            UIPasteboard.general.string = self
        #endif
    }
}
