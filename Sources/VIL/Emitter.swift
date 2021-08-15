import AST
import Basic

/// A VIL emitter.
///
/// VIL generation consists of transforming the high-level representation of Val (i.e., AST nodes)
/// into a lower-level language, better suited for data-flow analysis and code optimizations.
public enum Emitter {

  /// Lowers to VIL a module declaration into the specified builder.
  ///
  /// This method is the entry point to VIL code generation. It lowers a module declaration to its
  /// VIL representation, inserting VIL code into the module associated with the given builder.
  ///
  /// - Parameters:
  ///   - module: A module declaration. `module` must be type checked: all symbols must be resolved
  ///     or substituted by error nodes.
  ///   - builder: A VIL builder.
  public static func emit(module: ModuleDecl, into builder: Builder) {
    for decl in module {
      emit(topLevel: decl, into: builder)
    }
  }

  /// Lowers the given "top-level" declaration.
  public static func emit(topLevel decl: Decl, into builder: Builder) {
    switch decl {
    case let decl as ModuleDecl:
      emit(module: decl, into: builder)
    case is ImportDecl:
      fatalError("not implemented")
    case is PatternBindingDecl:
      fatalError("not implemented")
    case let decl as BaseFunDecl:
      emit(function: decl, into: builder)
    case let decl as ProductTypeDecl:
      emit(productType: decl, into: builder)
    case let decl as TypeExtnDecl:
      emit(typeExtn: decl, into: builder)

    case is ViewTypeDecl, is AbstractTypeDecl:
      // Views and abstract types are not concrete; there's nothing to emit.
      break

    case is AliasTypeDecl:
      // FIXME: Emit the type's witness table.
      break

    default:
      fatalError("unreachable")
    }
  }

  public static func emit(member decl: Decl, into builder: Builder) {
    switch decl {
    case let decl as PatternBindingDecl:
      // Pattern binding declarations are member properties in the context of a type declaration
      emit(property: decl, into: builder)

    default:
      emit(topLevel: decl, into: builder)
    }
  }

  public static func emit(property decl: PatternBindingDecl, into builder: Builder) {
    assert(decl.isMember)

    // FIXME: Emit computed properties and handle initializes in synthesized constructors.
    assert(decl.varDecls.isEmpty || decl.varDecls[0].hasStorage)
    assert(decl.initializer == nil)
  }

  /// Emits a local pattern binding declaration.
  static func emit(
    localBinding decl: PatternBindingDecl,
    funDecl: BaseFunDecl,
    locals: inout SymbolTable,
    into builder: Builder
  ) {
    // Create the variable locations for each name in the pattern.
    let lvalues = decl.pattern.namedPatterns.map({ pattern in
      emit(localVar: pattern.decl, locals: &locals, into: builder)
    })

    // Emit the initializer, if any.
    if let initializer = decl.initializer {
      // Emit a store right away if the pattern matches a single value.
      if let varDecl = decl.pattern.singleVarDecl {
        assert((lvalues.count == 1) && (lvalues[0] === locals[ObjectIdentifier(varDecl)]))
        emit(assign: initializer, to: lvalues[0], funDecl: funDecl, locals: &locals, into: builder)
      } else {
        // FIXME: Handle destructuring,
        fatalError("not implemented")
      }
    }
  }

  /// Emits a local variable declaration.
  static func emit(
    localVar decl: VarDecl,
    locals: inout SymbolTable,
    into builder: Builder
  ) -> Value {
    guard decl.state >= .typeChecked else {
      return ErrorValue(context: decl.type.context)
    }
    precondition(decl.hasStorage, "computed properties are not supported yet")

    // Allocate storage on the stack for the variable.
    let value = builder.buildAllocStack(type: .lower(decl.type))
    locals[ObjectIdentifier(decl)] = value
    return value
  }

  public static func emit(productType decl: ProductTypeDecl, into builder: Builder) {
    // Emit the the type's witness table(s).
    for conformance in decl.conformanceTable.values {
      var entries: [(decl: BaseFunDecl, impl: Function)] = []
      for (req, impl) in conformance.entries {
        if let reqFunDecl = req as? BaseFunDecl {
          let implFunDecl = impl as! BaseFunDecl
          let function = emit(witness: implFunDecl, for: reqFunDecl, into: builder)
          entries.append((reqFunDecl, function))
        }
      }

      let table = WitnessTable(
        type: decl.instanceType as! NominalType, view: conformance.viewType, entries: entries)
      builder.module.witnessTables.append(table)
    }

    // Emit the direct members of the declaration.
    for member in decl.members {
      emit(member: member, into: builder)
    }
  }

  public static func emit(typeExtn decl: TypeExtnDecl, into builder: Builder) {
    for member in decl.members {
      emit(member: member, into: builder)
    }
  }

  /// Emits a function.
  public static func emit(function decl: BaseFunDecl, into builder: Builder) {
    // Create (i.e., declare) the function in the module.
    let function = builder.getOrCreateFunction(from: decl)

    // We're done if the function doesn't have body.
    guard (decl.body != nil) || decl.isSynthesized else { return }

    // Contextualize the function's arguments.
    let genericEnv = decl.genericEnv!
    var args = function.type.paramTypes.map({ type -> Value in
      return ArgumentValue(
        type: type.contextualized(in: genericEnv, from: decl), function: function)
    })

    // Create the function's entry block.
    let currentBlock = builder.block
    defer { builder.block = currentBlock }
    builder.block = function.createBasicBlock(arguments: args)
    var locals: SymbolTable = [:]

    // Register the function's receiver in the local symbol table, if necessary.
    if let selfDecl = decl.selfDecl {
      var (selfType, _) = genericEnv.contextualize(selfDecl.type, from: decl)
      if decl.isMember {
        // Member functions accept their receiver as an implicit parameter.
        locals[ObjectIdentifier(selfDecl)] = args[0]
        args.removeFirst()
      } else {
        // Constructors should allocate `self`.
        assert(decl is CtorDecl)
        selfType = (selfType as! InoutType).base
        locals[ObjectIdentifier(selfDecl)] = builder.buildAllocStack(type: .lower(selfType))
      }
    }

    // Register the function's formal parameters in the local symbol table.
    let captures = decl.computeCaptures()
    for (ref, arg) in zip(captures, args) {
      locals[ObjectIdentifier(ref.decl)] = arg
    }
    for (param, arg) in zip(decl.params, args[captures.count...]) {
      locals[ObjectIdentifier(param)] = arg
    }

    // Emit the function's body.
    guard let body = decl.body else {
      return emit(synthesizedBodyOf: decl, locals: locals, into: builder)
    }

    emit(brace: body, funDecl: decl, locals: &locals, into: builder)

    // If the function's a constructor, emit the implicit return statement.
    if decl is CtorDecl {
      let selfLoc = locals[ObjectIdentifier(decl.selfDecl!)]
      let selfVal = builder.buildLoad(lvalue: selfLoc!)
      builder.buildRet(value: selfVal)
    }

    // Emit the function's epilogue.
    let funType = decl.type as! FunType
    let context = funType.context

    switch funType.retType {
    case context.nothingType:
      // If the function never returns, emit a halt statement.
      builder.buildHalt()

    case context.unitType:
      // The function returns unit.
      builder.buildRet(value: UnitValue(context: context))

    default:
      // The function should have a return statement.
      // FIXME: Handle non-returning blocks in last position.
      if !(builder.block?.instructions.last is RetInst) {
        let range = body.range.map({ $0.upperBound ..< $0.upperBound })
        context.report(.missingReturnValueInNonUnitFunction(range: range))
      }
    }
  }

  /// Emits the synthesized body of a function.
  static func emit(
    synthesizedBodyOf decl: BaseFunDecl,
    locals: SymbolTable,
    into builder: Builder
  ) {
    assert(decl.isSynthesized)

    switch decl {
    case is CtorDecl:
      // Emit a synthesized constructor.
      let base = locals[ObjectIdentifier(decl.selfDecl!)]!
      let type = decl.parentDeclSpace as! NominalTypeDecl

      for (varDecl, paramDecl) in zip(type.storedVars, decl.params) {
        let memberAddr = builder.buildRecordMemberAddr(
          record: base, memberDecl: varDecl, type: VILType.lower(varDecl.type).address)
        let value = locals[ObjectIdentifier(paramDecl)]!
        builder.buildStore(lvalue: memberAddr, rvalue: value)
      }

      let selfVal = builder.buildLoad(lvalue: base)
      builder.buildRet(value: selfVal)

    default:
      preconditionFailure("unexpected synthesized declaration '\(decl.name)'")
    }
  }

  /// Emits a function wrapping the implementation satisfying a conformance requirement.
  ///
  /// - Parameters:
  ///   - impl: The declaration of the function that implements the requirement.
  ///   - req: The declaration of the function requirement.
  ///   - builder: A VIL builder.
  static func emit(
    witness impl: BaseFunDecl,
    for req: BaseFunDecl,
    into builder: Builder
  ) -> Function {
    // Create the VIL function object.
    var mangler = Mangler()
    mangler.append(witnessImpl: impl, for: req)
    let name = mangler.finalize()
    let function = builder.getOrCreateFunction(name: name, type: req.unappliedType as! FunType)

    // Create the function's entry point.
    var args = function.type.paramTypes.map({ type -> Value in
      return ArgumentValue(type: type, function: function)
    })
    builder.block = function.createBasicBlock(arguments: args)

    // Emit the function's body.
    if !(req is CtorDecl) {
      // Unless the function is a constructor, we have to open the self parameter.
      let openedSelfType = impl.selfDecl!.type
      if req.isMutating {
        args[0] = builder.buildOpenExistentialAddr(container: args[0], type: .lower(openedSelfType))

        if !impl.isMutating {
          args[0] = builder.buildLoad(lvalue: args[0])
        }
      } else {
        assert(!impl.isMutating)
        args[0] = builder.buildOpenExistential(container: args[0], type: .lower(openedSelfType))
      }
    }

    let openedFun = builder.getOrCreateFunction(from: impl)
    let ret = builder.buildApply(fun: FunRef(function: openedFun), args: args)
    builder.buildRet(value: ret)

    return function
  }

  static func emit(
    brace: BraceStmt,
    funDecl: BaseFunDecl,
    locals: inout SymbolTable,
    into builder: Builder
  ) {
    assert(builder.block != nil, "not in a basic block")

    for i in 0 ..< brace.stmts.count {
      switch brace.stmts[i] {
      case let decl as PatternBindingDecl:
        emit(localBinding: decl, funDecl: funDecl, locals: &locals, into: builder)

      case let decl as FunDecl:
        emit(function: decl, into: builder)

        // Emit the value of each captured declaration.
        let partialArgs = decl.computeCaptures().map({ ref in
          emit(rvalue: ref, funDecl: funDecl, locals: &locals, into: builder)
        })

        // Local function with captures declarations require stack allocation.
        if !partialArgs.isEmpty {
          let fun = FunRef(function: builder.getOrCreateFunction(from: decl))
          let loc = builder.buildAllocStack(type: .lower(decl.type))

          locals[ObjectIdentifier(decl)] = loc
          builder.buildStore(
            lvalue: loc,
            rvalue: builder.buildPartialApply(fun: fun, args: partialArgs))
        }

      case let decl as NominalTypeDecl:
        emit(topLevel: decl, into: builder)

      case let stmt as BraceStmt:
        emit(brace: stmt, funDecl: funDecl, locals: &locals, into: builder)

      case let stmt as RetStmt:
        emit(stmt: stmt, funDecl: funDecl, locals: &locals, into: builder)
        if i > brace.stmts.count - 1 {
          let context = funDecl.type.context
          context.report(.codeAfterReturnNeverExecuted(range: brace.stmts[i + 1].range))
          return
        }

      case let expr as Expr:
        // FIXME: Drop the result of the expression.
        _ = emit(rvalue: expr, funDecl: funDecl, locals: &locals, into: builder)

      default:
        fatalError("unreachable")
      }
    }
  }

  static func emit(
    stmt: RetStmt,
    funDecl: BaseFunDecl,
    locals: inout SymbolTable,
    into builder: Builder
  ) {
    let result: Value
    if let expr = stmt.value {
      result = emit(rvalue: expr, funDecl: funDecl, locals: &locals, into: builder)
    } else {
      result = UnitValue(context: funDecl.type.context)
    }

    builder.buildRet(value: result)
  }

  /// Emits the assignment of the value represented by `expr` to `lvalue`.
  static func emit(
    assign expr: Expr,
    to lvalue: Value,
    funDecl: BaseFunDecl,
    locals: inout SymbolTable,
    into builder: Builder
  ) {
    // If both operands have an existential layout and the r-value can be treated as a location,
    // then we may simply emit `copy_addr`.
    if lvalue.type.valType.isExistential && expr.type.isExistential {
      var emitter = LValueEmitter(funDecl: funDecl, locals: locals, builder: builder)
      if case .success(var rvalue) = expr.accept(&emitter) {
        // If the r-value has a different type than the l-value, it must be casted.
        if lvalue.type.valType != expr.type {
          rvalue = builder.buildUnsafeCastAddr(source: rvalue, type: lvalue.type)
        }

        /// Copies the contents from the location on the right to the location on the left.
        builder.buildCopyAddr(dest: lvalue, source: rvalue)
        return
      }
    }

    // Otherwise, emit the r-value and fall back to the regular path.
    let rvalue = emit(rvalue: expr, funDecl: funDecl, locals: &locals, into: builder)
    let rvalueType = expr.type.dealiased.canonical
    emit(assign: rvalue, ofType: rvalueType, to: lvalue, into: builder)
  }

  /// Emits the assignment of `rvalue` to `lvalue`.
  static func emit(
    assign rvalue: Value,
    ofType rvalueType: ValType,
    to lvalue: Value,
    into builder: Builder
  ) {
    assert(rvalueType.isCanonical)

    // If the l-value has the same type as the r-value, we can emit a simple store.
    if lvalue.type.valType == rvalueType {
      builder.buildStore(lvalue: lvalue, rvalue: rvalue)
      return
    }

    // If both the l-value and the r-value have a union type, we can emit a simple store.
    if (rvalue.type.valType is UnionType) && (rvalueType is UnionType) {
      builder.buildStore(lvalue: lvalue, rvalue: rvalue)
      return
    }

    // If the l-value is an existential container, then there are two cases to consider.
    if lvalue.type.valType.isExistential {
      assert(lvalue.type.valType != rvalueType)

      if rvalueType.isExistential {
        // If the r-value is an existential container too (but with a different type), then we need
        // to cast its package.
        var tmp: Value = builder.buildAllocStack(type: rvalue.type)
        builder.buildStore(lvalue: tmp, rvalue: rvalue)
        tmp = builder.buildUnsafeCastAddr(source: tmp, type: lvalue.type)
        builder.buildCopyAddr(dest: lvalue, source: tmp)
      } else {
        // If the r-value has a concrete type, then it must be packed into an existential container
        // before being stored
        let lvalue = builder.buildAllocExistential(container: lvalue, witness: rvalue.type)
        builder.buildStore(lvalue: lvalue, rvalue: rvalue)
      }

      return
    }

    builder.buildStore(lvalue: lvalue, rvalue: rvalue)
  }

  /// Emits a r-value.
  static func emit(
    rvalue expr: Expr,
    funDecl: BaseFunDecl,
    locals: inout SymbolTable,
    into builder: Builder
  ) -> Value {
    // Emit an error value for any expression that has an error type.
    guard !(expr.type is ErrorType) else { return ErrorValue(context: expr.type.context) }

    // Note: We do not need to copy back the contents of `locals`, because evaluating an expression
    // never produces new bindings outside of that expression.
    var emitter = RValueEmitter(funDecl: funDecl, locals: locals, builder: builder)
    defer { locals = emitter.locals }

    switch expr.accept(&emitter) {
    case .success(let value):
      return value

    case .failure(let error):
      // FIXME: This should be reported.
      print(error)
      return ErrorValue(context: expr.type.context)
    }
  }

  /// Emits an l-value.
  func emit(
    lvalue expr: Expr,
    funDecl: BaseFunDecl,
    locals: SymbolTable,
    into builder: Builder
  ) -> Value {
    // Emit an error value for any expression that has an error type.
    guard !(expr.type is ErrorType) else { return ErrorValue(context: expr.type.context) }

    var emitter = LValueEmitter(funDecl: funDecl, locals: locals, builder: builder)
    switch expr.accept(&emitter) {
    case .success(let value):
      return value

    case .failure(let error):
      // FIXME: This should be reported.
      print(error)
      return ErrorValue(context: expr.type.context)
    }
  }

}
