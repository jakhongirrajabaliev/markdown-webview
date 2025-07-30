## Installation

### Swift Package Manager
```swift
https://github.com/jakhongirrajabaliev/markdown-webview
```
### Display Markdown Content

```swift
import SwiftUI
import MarkdownWebView

struct ContentView: View {
    @State private var markdownContent = "# Hello World"
    @State private var fontSize: CGFloat = 15
    @Environment(\.sizeCategory) var sizeCategory
    
    var body: some View {
        VStack {
            ScrollView {
                Slider(value: $fontSize, in: 10...30, step: 1) {
                    Text("Font Size")
                }
                Text("Current size: \(Int(fontSize))")
                MarkdownWebView(markdownContent, fontSize: effectiveFontSize)
                    .padding()
            }
        }
    }
    
    private var effectiveFontSize: CGFloat {
        return fontSize * scalingFactor(for: sizeCategory)
    }
    
    private func scalingFactor(for category: ContentSizeCategory) -> CGFloat {
        switch category {
        case .extraSmall: return 0.8
        case .small: return 0.9
        case .medium: return 1.0
        case .large: return 1.1
        case .extraLarge: return 1.2
        case .extraExtraLarge: return 1.3
        case .extraExtraExtraLarge: return 1.4
        case .accessibilityMedium: return 1.6
        case .accessibilityLarge: return 1.8
        case .accessibilityExtraLarge: return 2.0
        case .accessibilityExtraExtraLarge: return 2.2
        case .accessibilityExtraExtraExtraLarge: return 2.4
        @unknown default: return 1.0
        }
    }
}
```
