import SwiftyLLVM
import FrontEnd

extension SwiftyLLVM.FloatingPointPredicate {
  public init(_ p: FrontEnd.FloatingPointPredicate) {
    self = SwiftyLLVM.FloatingPointPredicate(rawValue: p.rawValue)!
  }
}
