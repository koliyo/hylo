/// A generic clause.
public struct GenericClause: Codable, Sendable {

  /// The parameters of the clause.
  public let parameters: [GenericParameterDecl.ID]

  /// The where clause of the generic clause, if any.
  public let whereClause: SourceRepresentable<WhereClause>?

  public init(
    parameters: [GenericParameterDecl.ID],
    whereClause: SourceRepresentable<WhereClause>? = nil
  ) {
    self.parameters = parameters
    self.whereClause = whereClause
  }

}
