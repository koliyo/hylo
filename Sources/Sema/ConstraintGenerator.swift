import AST

/// An AST visitor that generates type constraint equations from expressions.
final class ConstraintGenerator: NodeWalker {

  init(context: AST.Context) {
    self.context = context
    super.init()

    self.visitor = ConstraintVisitor(gen: self)
  }

  /// The context in which the pass runs.
  unowned let context: AST.Context

  /// The constraint system generated by the pass.
  var system = ConstraintSystem()

  /// The visitor extracts constraints from the AST.
  private var visitor: ConstraintVisitor!

  // MARK: Value declarations

  /// A FILO stack accumulating the function declarations we traversed up to the current node.
  fileprivate var funDeclStack: [AbstractFunDecl] = []

  public override func willVisit(_ decl: Decl) -> (shouldWalk: Bool, nodeBefore: Decl) {
    if let funDecl = decl as? AbstractFunDecl {
      funDeclStack.append(funDecl)
    }
    return (true, decl)
  }

  public override func didVisit(_ decl: Decl) -> (shouldContinue: Bool, nodeAfter: Decl) {
    decl.accept(visitor)
    if decl is AbstractFunDecl {
      funDeclStack.removeLast()
    }
    return (true, decl)
  }

  // MARK: Control statements

  public override func didVisit(_ stmt: Stmt) -> (shouldContinue: Bool, nodeAfter: Stmt) {
    stmt.accept(visitor)
    return (true, stmt)
  }

  // MARK: Expressions

  public override func didVisit(_ expr: Expr) -> (shouldContinue: Bool, nodeAfter: Expr) {
    expr.accept(visitor)
    return (true, expr)
  }

  // MARK: Type representations

  public override func willVisit(_ repr: TypeRepr) -> (shouldWalk: Bool, nodeBefore: TypeRepr) {
    // Skip type representations.
    return (false, repr)
  }

}

fileprivate struct ConstraintVisitor: NodeVisitor {

  typealias Result = Void

  unowned let gen: ConstraintGenerator

  func visit(_ node: Module) {
  }

  func visit(_ node: PatternBindingDecl) {
    // If the pattern has a signature, then we use it as the authoritative type information and
    // constrain the initializer with a subtyping relation.
    if let sign = node.typeSign {
      gen.system.insert(
        EqualityCons(node.pattern.type, isEqualTo: sign.type,
                     at: ConstraintLocator(node, .annotation)))
      if let initExpr = node.initializer {
        gen.system.insert(
          SubtypingCons(node.pattern.type, isSubtypeOf: initExpr.type,
                        at: ConstraintLocator(node, .initializer)))
      }
      return
    }

    // If the pattern has no signature, then we infer it from its initializer.
    if let initExpr = node.initializer {
      gen.system.insert(
        EqualityCons(node.pattern.type, isEqualTo: initExpr.type,
                     at: ConstraintLocator(node, .annotation)))
    }
  }

  func visit(_ node: VarDecl) {
  }

  func visit(_ node: AbstractFunDecl) {
    // Extract a function signature from the head of its declaration.
    let paramType = gen.context.tupleType(
      node.params.map({ param in
        TupleType.Elem(label: param.externalName, type: param.type)
      }))

    let retType: ValType
    if (node is CtorDecl) {
      // Constructors return instances of `Self`.
      retType = node.selfDecl!.type
    } else {
      // Assume the return type is `Unit` by default.
      retType = node.retTypeSign?.type ?? gen.context.unitType
    }

    let funSignType = gen.context.funType(paramType: paramType, retType: retType)

    // The extracted signature always correspond to applied function type, since the self parameter
    // is defined implicitly.
    gen.system.insert(
      EqualityCons(node.type, isEqualTo: funSignType, at: ConstraintLocator(node, .annotation)))
  }

  func visit(_ node: FunDecl) {
    visit(node as AbstractFunDecl)
  }

  func visit(_ node: CtorDecl) {
    visit(node as AbstractFunDecl)
  }

  func visit(_ node: FunParamDecl) {
    // If the pattern has a signature, then we use it as the authoritative type information.
    if let sign = node.typeSign {
      gen.system.insert(
        EqualityCons(node.type, isEqualTo: sign.type, at: ConstraintLocator(node, .application)))
    }
  }

  func visit(_ node: AbstractTypeDecl) {
  }

  func visit(_ node: ProductTypeDecl) {
  }

  func visit(_ node: ViewTypeDecl) {
  }

  func visit(_ node: BraceStmt) {
  }

  func visit(_ node: RetStmt) {
    guard let funDecl = gen.funDeclStack.last else { return }
    guard let funType = funDecl.type as? FunType else { return }

    let valType = node.value?.type ?? gen.context.unitType
    gen.system.insert(
      SubtypingCons(valType, isSubtypeOf: funType.retType,
                    at: ConstraintLocator(node, .returnType)))
  }

  func visit(_ node: IntLiteralExpr) {
    precondition(gen.context.stdlib != nil, "standard library is not loaded")

    // Retrieve the literal view from the standard library.
    let viewTypeDecl = gen.context.getTypeDecl(for: .ExpressibleByBuiltinIntLiteral)!

    // Create new constraints.
    gen.system.insert(
      ConformanceCons(node.type, conformsTo: viewTypeDecl.instanceType as! ViewType,
                      at: ConstraintLocator(node)))
  }

  func visit(_ node: AssignExpr) -> Void {
    gen.system.insert(
      SubtypingCons(node.rvalue.type, isSubtypeOf: node.lvalue.type,
                    at: ConstraintLocator(node, .assignment)))
  }

  func visit(_ node: CallExpr) {
    // Synthetize the type of a function from the call's arguments.
    var paramTypeElems: [TupleType.Elem] = []
    for arg in node.args {
      // The subtyping constraint handle cases where the argument is a subtype of the parameter.
      let paramType = TypeVar(context: gen.context, node: arg.value)
      gen.system.insert(
        SubtypingCons(arg.value.type, isSubtypeOf: paramType,
                      at: ConstraintLocator(node, .application)))
      paramTypeElems.append(TupleType.Elem(label: arg.label, type: paramType))
    }

    let funType = gen.context.funType(
      paramType: gen.context.tupleType(paramTypeElems),
      retType: node.type)
    gen.system.insert(
      EqualityCons(node.fun.type, isEqualTo: funType, at: ConstraintLocator(node.fun)))
  }

  func visit(_ node: UnresolvedDeclRefExpr) {
  }

  func visit(_ node: UnresolvedMemberExpr) {
    gen.system.insert(
      ValueMemberCons(node.base.type, hasValueMember: node.memberName, ofType: node.type,
                      at: ConstraintLocator(node, .valueMember(node.memberName))))
  }

  func visit(_ node: QualifiedDeclRefExpr) {
  }

  func visit(_ node: OverloadedDeclRefExpr) {
    precondition(node.declSet.count >= 1)
    gen.system.insertDisjuncConf(disjunctionOfConstraintsWithWeights: node.declSet.map({ decl in
      let constraint = EqualityCons(node.type, isEqualTo: decl.type, at: ConstraintLocator(node))
      return (constraint, 0)
    }))
  }

  func visit(_ node: DeclRefExpr) {
  }

  func visit(_ node: TypeDeclRefExpr) {
  }

  func visit(_ node: MemberRefExpr) {
  }

  func visit(_ node: AddrOfExpr) {
  }

  func visit(_ node: WildcardExpr) {
  }

  func visit(_ node: NamedPattern) {
  }

  func visit(_ node: TuplePattern) {
  }

  func visit(_ node: WildcardPattern) {
  }

  func visit(_ node: BuiltinTypeRepr) {
  }

  func visit(_ node: UnqualTypeRepr) {
  }

  func visit(_ node: CompoundTypeRepr) {
  }

}
