#if os(macOS) && DEBUG // comment
import AppKit
#elseif canImport(UIKit) /* block */
import UIKit
#else
import Foundation
#endif
#warning("check")
let file = #file
@available(macOS 14, *)
@MainActor @objc(name) @propertyWrapper
struct S {
    @Published var value = 0
    var `default` = 1
    let first = $0 + $12
    let projected = $value
    let half = `unterminated
    let at = @ 1
}
#Preview { }
