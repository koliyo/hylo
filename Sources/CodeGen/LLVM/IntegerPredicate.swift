import SwiftyLLVM
import FrontEnd

extension SwiftyLLVM.IntegerPredicate {
  public init(_ p: FrontEnd.IntegerPredicate) {
    self = SwiftyLLVM.IntegerPredicate(rawValue: p.rawValue)!
  }
}
