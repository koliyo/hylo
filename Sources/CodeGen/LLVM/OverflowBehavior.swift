import SwiftyLLVM
import FrontEnd

extension SwiftyLLVM.OverflowBehavior {
  public init(_ ob: FrontEnd.OverflowBehavior) {
    switch ob {
      case .ignore: self = OverflowBehavior.ignore
      case .nuw: self = OverflowBehavior.nuw
      case .nsw: self = OverflowBehavior.nsw
    }
  }
}
