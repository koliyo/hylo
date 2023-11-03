import Foundation

#if !os(macOS)
extension URL : @unchecked Sendable {

}
#endif
