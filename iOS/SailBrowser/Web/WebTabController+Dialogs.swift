import Foundation
import WebKit

extension WebTabController {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await dialogs.alert(message, host: frame.securityOrigin.host, in: webView)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        await dialogs.confirm(message, host: frame.securityOrigin.host, in: webView)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        await dialogs.prompt(prompt, defaultText: defaultText, host: frame.securityOrigin.host, in: webView)
    }

    func webView(
        _ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            return (.performDefaultHandling, nil)
        }
        guard let credential = await dialogs.signIn(host: challenge.protectionSpace.host, in: webView) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, credential)
    }
}
