//
//  MonacoViewController.swift
//  
//
//  Created by Pavel Kasila on 20.03.21.
//

#if os(macOS)
import AppKit
public typealias ViewController = NSViewController
#else
import UIKit
public typealias ViewController = UIViewController
#endif
import WebKit

public class MonacoViewController: ViewController, WKUIDelegate, WKNavigationDelegate {
    
    var delegate: MonacoViewControllerDelegate?
    
    var webView: WKWebView!
    
    public override func loadView() {
        let webConfiguration = WKWebViewConfiguration()
        let contentController = webConfiguration.userContentController

        contentController.add(UpdateTextScriptHandler(self), name: "updateText")

        let consoleHookJS = """
        (function() {
            const orig = {
                log: console.log,
                warn: console.warn,
                error: console.error,
                info: console.info,
                debug: console.debug
            };

            console.log = function () { orig.log.apply(console, arguments); send('log', arguments); };
            console.warn = function () { orig.warn.apply(console, arguments); send('warn', arguments); };
            console.error = function () { orig.error.apply(console, arguments); send('error', arguments); };
            console.info = function () { orig.info.apply(console, arguments); send('info', arguments); };
            console.debug = function () { orig.debug.apply(console, arguments); send('debug', arguments); };

            window.onerror = (message, source, lineno, colno, error) => {
                send('uncaughtError', [message, source, lineno, colno, error?.stack ?? null]);
            };

            window.onunhandledrejection = event => {
                const reason = event.reason ?? {};
                send('unhandledRejection', [reason.message ?? String(reason), reason.stack ?? null]);
            };

            function send(type, args) {
                try {
                    window.webkit.messageHandlers.console.postMessage({
                        type: type,
                        args: Array.prototype.slice.call(args).map(function(a) {
                            try { return JSON.stringify(a); } catch (e) { return String(a); }
                        })
                    });
                } catch (e) {
                }
            }
        })();
        """

        let consoleScript = WKUserScript(
            source: consoleHookJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(consoleScript)
        contentController.add(ConsoleScriptHandler(self), name: "console")

        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        #if os(iOS)
        webView.backgroundColor = .none
        #else
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        #endif
        view = webView
        #if os(macOS)
        DistributedNotificationCenter.default.addObserver(self, selector: #selector(interfaceModeChanged(sender:)), name: NSNotification.Name(rawValue: "AppleInterfaceThemeChangedNotification"), object: nil)
        #endif
    }
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        loadMonaco()
    }
    
    private func loadMonaco() {
        let myURL = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "_Resources")
        let myRequest = URLRequest(url: myURL!)
        webView.load(myRequest)
    }

    public func setText(_ text: String) {
        let b64 = text.data(using: .utf8)?.base64EncodedString() ?? ""
        evaluateJavascript("window.editor?.setText(atob('\(b64)'));")
    }

    public func setTypeScriptCompilerOptions(_ options: TypeScriptCompilerOptions?) {
        let literal = options?.toJavaScriptObjectLiteral() ?? "{}"
        evaluateJavascript("window.editor?.updateDefaultTypescriptCompilerOptions(\(literal));")
    }

    public func setTypeScriptExtraLibs(_ libs: [TypeScriptExtraLib]) {
        let libsJS = libs.map { lib -> String in
            let b64 = lib.content.data(using: .utf8)?.base64EncodedString() ?? ""
            let escapedPath = lib.filePath.replacingOccurrences(of: "'", with: "\\'")
            return "{ content: atob('\(b64)'), filePath: '\(escapedPath)' }"
        }.joined(separator: ",\n")

        evaluateJavascript("""
        window.editor?.withTypescript(typescript => {
            typescript.typescriptDefaults.setExtraLibs([
                \(libsJS)
            ]);
        });
        """)
    }

    // MARK: - Dark Mode
    private func updateTheme() {
        evaluateJavascript("""
        window.editor?.withMonaco(monaco => {
            monaco.editor.setTheme('\(detectTheme())');
        });
        """)
    }
    
    #if os(macOS)
    @objc private func interfaceModeChanged(sender: NSNotification) {
        updateTheme()
    }
    #else
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTheme()
    }
    #endif
    
    private func detectTheme() -> String {
        #if os(macOS)
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" {
            return "vs-dark"
        } else {
            return "vs"
        }
        #else
        switch traitCollection.userInterfaceStyle {
            case .light, .unspecified:
                return "vs"
            case .dark:
                return "vs-dark"
            @unknown default:
                return "vs"
        }
        #endif
    }
    
    // MARK: - WKWebView
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Syntax Highlighting
        let syntax = self.delegate?.monacoView(getSyntax: self)

        var syntaxJS: String
        let languageOptionJS: String

        switch syntax {

        case .monaco(let id):
            syntaxJS = ""
            languageOptionJS = ", language: '\(id)'"

        case .custom(let id, let config):
            syntaxJS = """
            monaco.languages.register({ id: '\(id)' });

            monaco.languages.setMonarchTokensProvider('\(id)', (function() {
                \(config)
            })());
            """
            languageOptionJS = ", language: '\(id)'"

        case .none:
            syntaxJS = ""
            languageOptionJS = ""
        }

        // TypeScript
        if let options = delegate?.monacoView(getTypeScriptCompilerOptions: self),
           !options.isEmpty {

            let literal = options.toJavaScriptObjectLiteral()
            syntaxJS += "editor.updateDefaultTypescriptCompilerOptions(\(literal));"
        }

        let tsExtraLibs = self.delegate?.monacoView(getTypeScriptExtraLibs: self) ?? []
        let tsExtraLibsJS = tsExtraLibs.map { lib -> String in
            let b64 = lib.content.data(using: .utf8)?.base64EncodedString() ?? ""
            let escapedPath = lib.filePath.replacingOccurrences(of: "'", with: "\\'")
            return """
            editor.withTypescript(typescript => {
                typescript.typescriptDefaults.addExtraLib(atob('\(b64)'), '\(escapedPath)');
            });
            """
        }.joined(separator: "\n")

        // Minimap
        let _minimap = self.delegate?.monacoView(getMinimap: self)
        let minimap = "minimap: { enabled: \(_minimap ?? true) }"
        
        // Scrollbar
        let _scrollbar = self.delegate?.monacoView(getScrollbar: self)
        let scrollbar = "scrollbar: { vertical: \(_scrollbar ?? true ? "\"visible\"" : "\"hidden\"") }"
        
        // Smooth Cursor
        let _smoothCursor = self.delegate?.monacoView(getSmoothCursor: self)
        let smoothCursor = "cursorSmoothCaretAnimation: \(_smoothCursor ?? false)"
        
        // Cursor Blinking
        let _cursorBlink = self.delegate?.monacoView(getCursorBlink: self)
        let cursorBlink = "cursorBlinking: \"\(_cursorBlink ?? .blink)\""
        
        // Font size
        let _fontSize = self.delegate?.monacoView(getFontSize: self)
        let fontSize = "fontSize: \(_fontSize ?? 12)"
        
        var theme = detectTheme()
        
        if let _theme = self.delegate?.monacoView(getTheme: self) {
            switch _theme {
            case .light:
                theme = "vs"
            case .dark:
                theme = "vs-dark"
            }
        }
        
        
        // Code itself
        let text = self.delegate?.monacoView(readText: self) ?? ""
        let b64 = text.data(using: .utf8)?.base64EncodedString()
        let javascript =
        """
        editor.withMonaco(monaco => {
        \(syntaxJS)
        \(tsExtraLibsJS)

        editor.create({value: atob('\(b64 ?? "")'), automaticLayout: true, theme: "\(theme)"\(languageOptionJS), \(minimap), \(scrollbar), \(smoothCursor), \(cursorBlink), \(fontSize)});
        var meta = document.createElement('meta'); meta.setAttribute('name', 'viewport'); meta.setAttribute('content', 'width=device-width'); document.getElementsByTagName('head')[0].appendChild(meta);
        return true;
        });
        """
        evaluateJavascript(javascript)
    }
    
    private func evaluateJavascript(_ javascript: String) {
        webView.evaluateJavaScript(javascript, in: nil, in: WKContentWorld.page) {
          result in
          switch result {
          case .failure(let error as NSError):
            let limit = 200
            let shortJS = String(javascript.prefix(limit))

            var message = "Something went wrong while evaluating the following JavaScript:\n"
            message += "\(shortJS)\(javascript.count > limit ? "…" : "")\n\n"

            message += "Description: \(error.localizedDescription)\n"

            if let exception = error.userInfo["WKJavaScriptExceptionMessage"] as? String {
                message += "Exception: \(exception)\n"
            }

            if let line = error.userInfo["WKJavaScriptExceptionLineNumber"] {
                message += "Line: \(line)\n"
            }

            if let column = error.userInfo["WKJavaScriptExceptionColumnNumber"] {
                message += "Column: \(column)\n"
            }

            #if os(macOS)
            let alert = NSAlert()
            alert.messageText = "JavaScript Error"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
            #else
            let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
            alert.addAction(.init(title: "OK", style: .default, handler: nil))
            self.present(alert, animated: true, completion: nil)
            #endif
            break
          case .success(_):
            break
          }
        }
    }
}

// MARK: - Handler

private extension MonacoViewController {
    final class UpdateTextScriptHandler: NSObject, WKScriptMessageHandler {
        private let parent: MonacoViewController

        init(_ parent: MonacoViewController) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
            ) {
            guard let encodedText = message.body as? String,
            let data = Data(base64Encoded: encodedText),
            let text = String(data: data, encoding: .utf8) else {
                fatalError("Unexpected message body")
            }

            parent.delegate?.monacoView(controller: parent, textDidChange: text)
        }
    }

    final class ConsoleScriptHandler: NSObject, WKScriptMessageHandler {
        private unowned let parent: MonacoViewController

        init(_ parent: MonacoViewController) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard
                let dict = message.body as? [String: Any],
                let typeString = dict["type"] as? String,
                let argsAny = dict["args"] as? [Any]
            else {
                return
            }

            let level = MonacoConsoleMessage.Level(rawValue: typeString) ?? .log
            let args = argsAny.map { String(describing: $0) }

            let consoleMessage = MonacoConsoleMessage(level: level, arguments: args)
            parent.delegate?.monacoView(controller: parent,
                                        didReceiveConsoleMessage: consoleMessage)
        }
    }
}

// MARK: - Delegate

public protocol MonacoViewControllerDelegate {
    func monacoView(readText controller: MonacoViewController) -> String
    func monacoView(getSyntax controller: MonacoViewController) -> SyntaxHighlight?
    func monacoView(getTypeScriptCompilerOptions controller: MonacoViewController) -> TypeScriptCompilerOptions?
    func monacoView(getTypeScriptExtraLibs controller: MonacoViewController) -> [TypeScriptExtraLib]
    func monacoView(getMinimap controller: MonacoViewController) -> Bool
    func monacoView(getScrollbar controller: MonacoViewController) -> Bool
    func monacoView(getSmoothCursor controller: MonacoViewController) -> Bool
    func monacoView(getCursorBlink controller: MonacoViewController) -> CursorBlink
    func monacoView(getFontSize controller: MonacoViewController) -> Int
    func monacoView(getTheme controller: MonacoViewController) -> Theme?
    func monacoView(controller: MonacoViewController, textDidChange: String)
    func monacoView(controller: MonacoViewController, didReceiveConsoleMessage message: MonacoConsoleMessage)
}

public struct MonacoConsoleMessage {
    public enum Level: String {
        case log
        case warn
        case error
        case info
        case debug
        case uncaughtError
        case unhandledRejection
    }

    public let level: Level
    public let arguments: [String]
}
