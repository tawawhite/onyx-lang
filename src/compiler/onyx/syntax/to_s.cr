require "../../crystal/syntax/to_s"

module Crystal

class ToOnyxSVisitorsPool
  @@pool = [] of ToOnyxSVisitor

  def self.borrow_tos_visitor(io, emit_loc_pragma = false) : ToOnyxSVisitor
    if @@pool.size > 0
      visitor = @@pool.pop.not_nil!
      visitor.re_init io, emit_loc_pragma
      visitor.not_nil!
    else
      ToOnyxSVisitor.new(io, emit_loc_pragma)
    end
  end

  def self.with_borrowed_tos_visitor(io, emit_loc_pragma = false, &block)
    visitor = borrow_tos_visitor io, emit_loc_pragma
    ret = yield visitor
    leave_tos_visitor visitor
    ret
  end

  def self.leave_tos_visitor(visitor : ToOnyxSVisitor) : Nil
    @@pool << visitor
    nil
  end
end

class ToSVisitorsPool
  @@pool = [] of ToSVisitor

  def self.borrow_tos_visitor(io, emit_loc_pragma = false) : ToSVisitor
    if @@pool.size > 0
      visitor = @@pool.pop.not_nil!
      visitor.re_init io, emit_loc_pragma
      visitor.not_nil!
    else
      ToSVisitor.new(io, emit_loc_pragma)
    end
  end

  def self.with_borrowed_tos_visitor(io, emit_loc_pragma = false, &block)
    visitor = borrow_tos_visitor io, emit_loc_pragma
    ret = yield visitor
    leave_tos_visitor visitor
    ret
  end

  def self.leave_tos_visitor(visitor : ToSVisitor) : Nil
    @@pool << visitor
    nil
  end
end


class ASTNode
  def to_oxs()
    to_s nil, false, :onyx
  end

  def to_s(io : Nil, emit_loc_pragma : Bool = false, lang : Symbol = :auto)
    str = MemoryIO.new
    to_s str, emit_loc_pragma, lang
    str.to_s # *TODO* needed?
  end

  # def to_s(io, emit_loc_pragma = false)
  #   visitor = ToSVisitor.new(io, emit_loc_pragma: emit_loc_pragma)
  #   self.accept visitor
  # end

  def to_s(io, emit_loc_pragma = false, lang = :auto)
    if OptTests.test_opt_mode_b == 1
      if (lang == :auto && @is_onyx) || lang == :onyx
        visitor = ToOnyxSVisitor.new(io, emit_loc_pragma: emit_loc_pragma)
        self.accept visitor
      else
        visitor = ToSVisitor.new(io, emit_loc_pragma: emit_loc_pragma)
        self.accept visitor
      end

    else
      # _dbg "ASTNode.to_s -> lang = #{lang}, self.class = #{self.class}"
      if (lang == :auto && @is_onyx) || lang == :onyx
        ToOnyxSVisitorsPool.with_borrowed_tos_visitor io, emit_loc_pragma: emit_loc_pragma do |visitor|
          self.accept visitor
        end
      else
        ToSVisitorsPool.with_borrowed_tos_visitor io, emit_loc_pragma: emit_loc_pragma do |visitor|
          self.accept visitor
        end
      end
    end
  end
end


class ToOnyxSVisitor < Visitor
  @str : IO

  def initialize(@str = MemoryIO.new, @emit_loc_pragma = false)
    @indent = 0
    @inside_macro = 0
    @inside_lib = false
  end

  def re_init(str = MemoryIO.new, emit_loc_pragma = false)
    initialize str, emit_loc_pragma
  end

  def visit_any(node)
    return true unless @emit_loc_pragma

    location = node.location
    return true unless location

    filename = location.filename
    return true unless filename.is_a?(String)

    @str << "--<loc:"
    filename.inspect(@str)
    @str << ","
    @str << location.line_number
    @str << ","
    @str << location.column_number
    @str << ">"

    true
  end

  # *TODO* - missing in CR - why does it work there?
  def visit(node : Primitive)
    @str << "-- primitive: "
    @str << node.name
  end

  def visit(node : Nop)
  end

  def visit(node : BoolLiteral)
    @str << decorate_singleton(node, (node.value ? "true" : "false"))
  end

  def visit(node : NumberLiteral)
    @str << node.value
    if node.kind != :int && !node.kind.to_s.starts_with? "unspec_" # != :i32 && node.kind != :f64
      @str << "_" # *TEMP* *DEBUG*
      @str << node.kind.to_s
    end
  end

  def visit(node : CharLiteral)
    # node.value.inspect(@str)
    @str << "%\"#{node.value}\"" # *TODO* must ofc handle \n, \x{...} etc. for non std's
  end

  def visit(node : SymbolLiteral)
    @str << '#'

    value = node.value
    if Symbol.needs_quotes?(value)
      value.inspect(@str)
    else
      value.to_s(@str)
    end
  end

  def visit(node : StringLiteral)
    node.value.inspect(@str)
  end

  def visit(node : StringInterpolation)
    @str << %(")
    visit_interpolation node, &.gsub('"', "\\\"")
    @str << %(")
    false
  end

  def visit_interpolation(node)
    node.expressions.each do |exp|
      if exp.is_a?(StringLiteral)
        @str << yield exp.value.gsub('"', "\\\"")
      else
        startDelim = "{"
        endDelim = "}"

        @str << startDelim
        exp.accept(self)
        @str << endDelim
      end
    end
  end

  def visit(node : ArrayLiteral)
    name = node.name
    if name == "Set"
      @str << " {"

    elsif name
      name.accept self
      @str << " {"

    else
      @str << "["
    end

    node.elements.each_with_index do |exp, i|
      @str << ", " if i > 0
      exp.accept self
    end

    if name
      @str << "}"
    else
      @str << "]"
    end

    if of = node.of
      @str << " "
      @str << keyword("of")
      @str << " "
      of.accept self
    end
    false
  end

  def visit(node : HashLiteral)
    if name = node.name
      name.accept self
      @str << " "
    end

    @str << "{"
    node.entries.each_with_index do |entry, i|
      @str << ", " if i > 0
      entry.key.accept self
      @str << " => "
      entry.value.accept self
    end
    @str << "}"
    if of = node.of
      @str << " "
      @str << keyword("of")
      @str << " "
      of.key.accept self
      @str << " => "
      of.value.accept self
    end
    false
  end

  def visit(node : NamedTupleLiteral)
    @str << "("
    node.entries.each_with_index do |entry, i|
      @str << ", " if i > 0
      visit_named_arg_name(entry.key)
      @str << ": "
      entry.value.accept self
    end
    @str << ")"
    false
  end

  def visit(node : NilLiteral)
    @str << decorate_singleton(node, "nil")
  end

  def visit(node : Expressions)
    if @inside_macro > 0
      node.expressions.each &.accept self
    else
      node.expressions.each do |exp|
        unless exp.nop?
          append_indent
          exp.accept self
          newline
        end
      end
    end
    false
  end

  def visit(node : If)
    visit_if_or_unless "if", node
  end

  def visit(node : Unless)
    visit_if_or_unless "unless", node
  end

  def visit(node : IfDef)
    visit_if_or_unless "ifdef", node
  end

  def visit_if_or_unless(prefix, node)
    @str << keyword(prefix)
    @str << " "
    node.cond.accept self
    newline
    accept_with_indent(node.then)
    unless node.else.nop?
      append_indent
      @str << keyword("else")
      newline
      accept_with_indent(node.else)
    end
    append_indent
    @str << keyword("end")
    false
  end

  def visit(node : ExtendTypeDef)
    if node.expanded
      node.expanded.try &.accept self
    else
      @str << keyword("extend")
      @str << " "
      @str << node.name.accept self
      newline
      if body = node.body
        accept_with_indent body
      end
    end
  end

  def visit(node : ClassDef)
    @str << keyword("type")
    @str << " "
    node.name.accept self

    if type_vars = node.type_vars
      @str << "<"
      type_vars.each_with_index do |type_var, i|
        @str << ", " if i > 0
        @str << type_var.to_s
      end
      @str << ">"
    end

    if (superclass = node.superclass) || node.struct? || node.abstract?
      @str << " <"

      if node.abstract?
        @str << " "
        @str << keyword("abstract")
      end

      if node.struct?
        @str << " "
        @str << keyword("value")
      end

      if superclass
        @str << " "
        superclass.accept self
      end
    end

    newline
    accept_with_indent(node.body)

    append_indent
    @str << keyword("end")
    newline

    false
  end

  def visit(node : ModuleDef)
    @str << keyword("module")
    @str << " "
    node.name.accept self
    if type_vars = node.type_vars
      @str << "<"
      type_vars.each_with_index do |type_var, i|
        @str << ", " if i > 0
        @str << type_var
      end
      @str << ">"
    end
    newline
    accept_with_indent(node.body)

    append_indent
    @str << keyword("end")
    false
  end

  def visit(node : Call)
    visit_call node
  end

  def visit_call(node, ignore_obj = false)
    if node.name == "`"
      visit_backtick(node.args[0])
      return false
    end

    node_obj = ignore_obj ? nil : node.obj

    if node.name == "new"
      is_new = node_obj.is_a?(Generic) || (node_obj.is_a?(Path) && ('A' <= node_obj.names.last.to_s[0] <= 'Z'))
    else
      is_new = false
    end

    need_parens =
      case node_obj
      when Call
        case node_obj.args.size
        when 0
          !is_alpha(node_obj.name)
        else
          true
        end
      when Var, NilLiteral, BoolLiteral, CharLiteral, NumberLiteral, StringLiteral,
           StringInterpolation, Path, Generic, InstanceVar, Global
        false
      when ArrayLiteral
        !!node_obj.of
      when HashLiteral
        !!node_obj.of
      else
        true
      end
    call_args_need_parens = false

    @str << "$." if node.global?

    case
    when is_new
      node_obj = node_obj.not_nil!
      in_parenthesis(need_parens, node_obj)
      call_args_need_parens = node.args.empty?
      @str << (call_args_need_parens ? "(" : " ")
      printed_arg = false
      node.args.each_with_index do |arg, i|
        @str << ", " if printed_arg
        arg_needs_parens = arg.is_a?(Cast)
        in_parenthesis(arg_needs_parens) { arg.accept self }
        printed_arg = true
      end
      if named_args = node.named_args
        named_args.each do |named_arg|
          @str << ", " if printed_arg
          named_arg.accept self
          printed_arg = true
        end
      end
      if block_arg = node.block_arg
        @str << ", " if printed_arg
        @str << "&"
        block_arg.accept self
      end

    when node_obj && (node.name == "[]" || node.name == "[]?")
      in_parenthesis(need_parens, node_obj)

      @str << decorate_call(node, "[")

      node.args.each_with_index do |arg, i|
        @str << ", " if i > 0
        arg.accept self
      end

      if node.name == "[]"
        @str << decorate_call(node, "]")
      else
        @str << decorate_call(node, "]?")
      end
    when node_obj && node.name == "[]="
      in_parenthesis(need_parens, node_obj)

      @str << decorate_call(node, "[")

      node.args[0].accept self
      @str << decorate_call(node, "]")
      @str << " "
      @str << decorate_call(node, "=")
      @str << " "
      node.args[1].accept self
    when node_obj && !is_alpha(node.name) && node.args.size == 0
      @str << decorate_call(node, node.name)
      in_parenthesis(need_parens, node_obj)
    when node_obj && !is_alpha(node.name) && node.args.size == 1
      in_parenthesis(need_parens, node_obj)

      @str << " "
      @str << decorate_call(node, node.name)
      @str << " "
      node.args[0].accept self
    else
      if node_obj
        in_parenthesis(need_parens, node_obj)
        @str << "."
      end
      if node.name.ends_with?('=')
        @str << decorate_call(node, node.name[0..-2])
        @str << " = "
        node.args.each_with_index do |arg, i|
          @str << ", " if i > 0
          arg.accept self
        end
      else
        @str << decorate_call(node, node.name)

        call_args_need_parens = !node.args.empty? || node.block_arg || node.named_args
        @str << "(" if call_args_need_parens

        printed_arg = false
        node.args.each_with_index do |arg, i|
          @str << ", " if printed_arg
          arg_needs_parens = arg.is_a?(Cast)
          in_parenthesis(arg_needs_parens) { arg.accept self }
          printed_arg = true
        end
        if named_args = node.named_args
          named_args.each do |named_arg|
            @str << ", " if printed_arg
            named_arg.accept self
            printed_arg = true
          end
        end
        if block_arg = node.block_arg
          @str << ", " if printed_arg
          @str << "&"
          block_arg.accept self
        end
      end
    end

    block = node.block

    if block
      # Check if this is foo &.bar
      first_block_arg = block.args.first?
      if first_block_arg && block.args.size == 1
        block_body = block.body
        if block_body.is_a?(Call)
          block_obj = block_body.obj
          if block_obj.is_a?(Var) && block_obj.name == first_block_arg.name
            if node.args.empty?
              @str << "("
            else
              @str << ", "
            end
            @str << "~."
            visit_call block_body, ignore_obj: true
            @str << ")"
            return false
          end
        end
      end
    end

    if block
      @str << "," if node.args.size > 0
      @str << " "
      block.accept self
    end

    @str << ")" if call_args_need_parens

    false
  end

  def in_parenthesis(need_parens)
    if need_parens
      @str << "("
      yield
      @str << ")"
    else
      yield
    end
  end

  def in_parenthesis(need_parens, node)
    in_parenthesis(need_parens) do
      if node.is_a?(Expressions) && node.expressions.size == 1
        node.expressions.first.accept self
      else
        node.accept self
      end
    end
  end

  def visit(node : NamedArgument)
    visit_named_arg_name(node.name)
    @str << ": "
    node.value.accept self
    false
  end

  def visit(node : MacroId)
    @str << node.value
    false
  end

  def visit(node : TypeNode)
    node.type.to_s(@str)
    false
  end

  def visit_backtick(exp)
    @str << '`'
    case exp
    when StringLiteral
      @str << exp.value.inspect[1..-2]
    when StringInterpolation
      visit_interpolation exp, &.gsub('`', "\\`")
    end
    @str << '`'
    false
  end

  def stylize_idfr(str, literal_style : Symbol)
    encountered_alpha = false
    delimiter_count = 0
    String.build str.size, do |ret|
      str.each_char_with_index do |chr, i|
        is_last_char = (i + 1 == str.size)
        if chr == '_'
          delimiter_count += 1
        end
        if chr != '_' || is_last_char
          if delimiter_count > 0
            if is_last_char || !encountered_alpha
              ret << "_" * delimiter_count
            else
              ret << "-" * delimiter_count
            end
            delimiter_count = 0
          end

          ret << chr unless chr == '_'
          encountered_alpha = true
        end
      end
    end
  end

  def keyword(str)
    str
  end

  def func_name(str, literal_style : Symbol)
    stylize_idfr str, literal_style
  end

  def decorate_singleton(node, str)
    stylize_idfr str, :dash
  end

  def decorate_call(node, str)
    stylize_idfr str, :dash
  end

  def decorate_var(node, str)
    stylize_idfr str, :dash
  end

  def decorate_arg(node, str)
    stylize_idfr str, :dash
  end

  def decorate_instance_var(node, str)
    stylize_idfr str, :dash
  end

  def decorate_class_var(node, str)
    stylize_idfr str, :dash
  end

  def is_alpha(string)
    'a' <= string[0].downcase <= 'z'
  end

  def visit(node : Assign)
    node.target.accept self
    @str << " = "
    accept_with_maybe_begin_end node.value
    false
  end

  def visit(node : MultiAssign)
    @str << "["
    node.targets.each_with_index do |target, i|
      @str << ", " if i > 0
      target.accept self
    end
    @str << "]"

    @str << " = "

    node.values.each_with_index do |value, i|
      @str << ", " if i > 0
      value.accept self
    end
    false
  end

  def visit(node : For)

    # *TODO* each|for
    @str << "for "

    if node.value_id && node.index_id
      node.value_id.try &.accept self
      @str << ", "
      node.index_id.try &.accept self

    elsif node.value_id
      node.value_id.try &.accept self

    elsif node.index_id
      @str << ","
      node.index_id.try &.accept self

    else
      # nothing
    end

    @str << " in "
    node.iterable.accept self
    newline

    accept_with_indent(node.body)
    append_indent

    # *TODO* by|step

    @str << "end"
    false
  end

  def visit(node : While)
    visit_while_or_until node, "while"
  end

  def visit(node : Until)
    visit_while_or_until node, "until"
  end

  def visit_while_or_until(node, name)
    @str << keyword(name)
    @str << " "
    node.cond.accept self
    newline
    accept_with_indent(node.body)
    append_indent
    @str << keyword("end")
    false
  end

  def visit(node : Out)
    @str << "out "
    node.exp.accept self
    false
  end

  def visit(node : Var)
    @str << decorate_var(node, node.name)
  end

  def visit(node : MetaVar)
    @str << node.name
  end

  def visit(node : ProcLiteral)
    # if node.def.args.size > 0
    @str << "("
    node.def.args.each_with_index do |arg, i|
      @str << ", " if i > 0
      arg.accept self
    end
    @str << ")"
    # end
    @str << " "
    @str << "->"
    @str << " "
    # @str << keyword("do")
    newline
    accept_with_indent(node.def.body)
    append_indent
    # @str << keyword("end")
    false
  end

  def visit(node : ProcPointer)
    @str << "->"
    if obj = node.obj
      obj.accept self
      @str << "."
    end
    @str << func_name(node.name, :dash)

    if node.args.size > 0
      @str << "("
      node.args.each_with_index do |arg, i|
        @str << ", " if i > 0
        arg.accept self
      end
      @str << ")"
    end
    false
  end

  def visit(node : Def)
    @str << "macro " if node.macro_def?

    # if context needs it - output ORIGINAL, or specific CHOICE OF "\", "λ", "def " (stylize mode)
    # kwd_choice = "\\"
    # @str << keyword(kwd_choice)
    # @str << " "

    if node_receiver = node.receiver
      if node_receiver.to_s == "self"
        @str << "Self"
      else
        node_receiver.accept self
      end
      @str << "."
    end

    case node.name

    # *TODO* not entirely correct - must discern that we're on a typedef!
    when "initialize"
      @str << func_name("init", :snake)

    when "===" # *TODO*
      @str << func_name("~~", :snake)

    else
      @str << func_name(node.name, :dash)
      @str << case node.visibility
      when Visibility::Public then ""
      when Visibility::Protected then "*"
      when Visibility::Private then "**"
      else raise "I'm not aware of the visibility mode '#{node.visibility}'"
      end
    end

    @str << "("
    node.args.each_with_index do |arg, i|
      @str << ", " if i > 0
      @str << "..." if node.splat_index == i
      arg.accept self
    end
    if block_arg = node.block_arg
      @str << ", " if node.args.size > 0
      @str << "&"
      block_arg.accept self
    end
    @str << ")"

    # *TODO* return–type can be entered both before and after `->` - keep track in AST
    if return_type = node.return_type
      @str << " "
      return_type.accept self
    end

    # *TODO* `!` etc. modifiers
    @str << " ->"

    if node.abstract?
      @str << " abstract"

    else
      # *TODO* also here - keep track of if there actually IS a newline (stylize mode)
      newline
      accept_with_indent(node.body)
      append_indent

      # *TODO* only if there WAS an end originally
      # @str << keyword("end")
    end
    false
  end

  def visit(node : Macro)
    @str << keyword("macro")
    @str << " "
    @str << node.name.to_s
    if node.args.size > 0 || node.block_arg
      @str << "("
      node.args.each_with_index do |arg, i|
        @str << ", " if i > 0
        arg.accept self
      end
      if block_arg = node.block_arg
        @str << ", " if node.args.size > 0
        @str << "&"
        block_arg.accept self
      end
      @str << ")"
    end
    newline

    inside_macro do
      accept_with_indent node.body
    end

    # newline
    append_indent
    @str << keyword("end")
    false
  end

  def visit(node : MacroExpression)
    @str << (node.output? ? "{=" : "{% ")
    @str << " " if node.output?
    node.exp.accept self
    @str << " " if node.output?
    @str << (node.output? ? "=}" : " %}")
    false
  end

  def visit(node : MacroIf)
    @str << "{% if "
    node.cond.accept self
    @str << " %}"
    inside_macro do
      node.then.accept self
    end
    unless node.else.nop?
      @str << "{% else %}"
      inside_macro do
        node.else.accept self
      end
    end
    @str << "{% end %}"
    false
  end

  def visit(node : MacroFor)
    @str << "{% for "
    node.vars.each_with_index do |var, i|
      @str << ", " if i > 0
      var.accept self
    end
    @str << " in "
    node.exp.accept self
    @str << " %}"
    inside_macro do
      node.body.accept self
    end
    @str << "{% end %}"
    false
  end

  def visit(node : MacroVar)
    @str << '%'
    @str << node.name
    if exps = node.exps
      @str << '{'
      exps.each_with_index do |exp, i|
        @str << ", " if i > 0
        exp.accept self
      end
      @str << '}'
    end
    false
  end

  def visit(node : MacroLiteral)
    @str << node.value
    false
  end

  def visit(node : External)
    node.fun_def?.try &.accept self
    false
  end

  def visit(node : ExternalVar)
    @str << "$"
    @str << node.name
    if real_name = node.real_name
      @str << " = "
      @str << real_name
    end
    @str << " : "
    node.type_spec.accept self
    false
  end

  def visit(node : Arg)
    if node.external_name != node.name
      visit_named_arg_name(node.external_name)
      @str << " => "
    end

    if node.name
      @str << decorate_arg(node, node.name)
    else
      @str << "?"
    end

    if restriction = node.restriction
      @str << " "
      to_s_mutability node.mutability
      if restriction.is_a? Underscore
        @str << "*"
      else
        restriction.accept self
      end
    end

    if default_value = node.default_value
      @str << " = "
      default_value.accept self
    end
    false
  end

  # def visit(node : BlockArg)
  #   @str << node.name
  #   if a_fun = node.fun
  #     @str << " : "
  #     a_fun.accept self
  #   end
  #   false
  # end

  def visit(node : ProcNotation)
    @str << "("
    if inputs = node.inputs
      inputs.each_with_index do |input, i|
        @str << ", " if i > 0
        input.accept self
      end
      @str << " "
    end
    @str << ")"
    @str << " ->"
    if output = node.output
      @str << " "
      output.accept self
    end
  end

  def visit(node : Self)
    @str << keyword("Self")
  end

  def visit(node : Path)
    _dbg "onyx-to_s: #{node.names}, is_onyx: #{node.is_onyx}"

    @str << "$." if node.global?
    node.names.each_with_index do |name, i|
      @str << "." if i > 0
      @str << name
    end
  end

  def visit(node : Generic)
    if @inside_lib && node.name.names.size == 1
      case node.name.names.first
      # when "Pointer"
      #   node.type_vars.first.accept self
      #   @str << "*"
      #   return false
      when "StaticArray"
        if node.type_vars.size == 2
          node.type_vars[0].accept self
          @str << "<"
          node.type_vars[1].accept self
          @str << ">"
          return false
        end
      end
    end

    node.name.accept self

    printed_arg = false

    @str << "‹"
    node.type_vars.each_with_index do |var, i|
      @str << ", " if i > 0
      var.accept self
      printed_arg = true
    end

    if named_args = node.named_args
      named_args.each do |named_arg|
        @str << ", " if printed_arg
        visit_named_arg_name(named_arg.name)
        @str << ": "
        named_arg.value.accept self
        printed_arg = true
      end
    end
    @str << "›"
    false
  end

  def visit_named_arg_name(name)
    if Symbol.needs_quotes?(name)
      name.inspect(@str)
    else
      @str << name
    end
  end

  def visit(node : Underscore)
    @str << "_"
    false
  end

  def visit(node : Splat)
    @str << "*"
    node.exp.accept self
    false
  end

  def visit(node : DoubleSplat)
    @str << "*:"
    node.exp.accept self
    false
  end

  def visit(node : Union)
    node.types.each_with_index do |ident, i|
      @str << " | " if i > 0
      ident.accept self
    end
    false
  end

  def visit(node : Metaclass)
    node.name.accept self
    @str << "."
    @str << keyword("class")
    false
  end

  def visit(node : InstanceVar)
    @str << decorate_instance_var(node, node.name)
  end

  def visit(node : ReadInstanceVar)
    node.obj.accept self
    @str << "."
    @str << node.name
    false
  end

  def visit(node : ClassVar)
    @str << decorate_class_var(node, node.name)
  end

  def visit(node : Yield)
    if scope = node.scope
      @str << "with "
      scope.accept self
      @str << " "
    end
    @str << keyword("yield")
    if node.exps.size > 0
      @str << " "
      node.exps.each_with_index do |exp, i|
        @str << ", " if i > 0
        exp.accept self
      end
    end
    false
  end

  def visit(node : Return)
    visit_control node, "return"
  end

  def visit(node : Break)
    visit_control node, "break"
  end

  def visit(node : Next)
    visit_control node, "next"
  end

  def visit_control(node, keyword)
    @str << keyword(keyword)
    if exp = node.exp
      @str << " "
      accept_with_maybe_begin_end exp
    end
    false
  end

  def visit(node : RegexLiteral)
    # @str << "re\""
    @str << "/"
    case exp = node.value
    when StringLiteral
      @str << exp.value
    when StringInterpolation
      visit_interpolation exp, &.gsub('/', "\\/")
    end
    # @str << "\""
    @str << "/"
    @str << "i" if node.options.includes? Regex::Options::IGNORE_CASE
    @str << "m" if node.options.includes? Regex::Options::MULTILINE
    @str << "x" if node.options.includes? Regex::Options::EXTENDED
  end

  def visit(node : TupleLiteral)
    @str << "("
    node.elements.each_with_index do |exp, i|
      @str << ", " if i > 0
      exp.accept self
    end
    @str << "," if node.elements.size < 2
    @str << ")"
    false
  end

  def visit(node : TypeDeclaration)
    node.var.accept self
    @str << " "
    to_s_mutability node.mutability
    node.declared_type.accept self
    if value = node.value
      @str << " = "
      value.accept self
    end
    false
  end

  def visit(node : UninitializedVar)
    node.var.accept self
    @str << " = raw "
    node.declared_type.accept self
    false
  end

  def to_s_mutability(flag : Symbol)
    @str << case flag
    when :auto
      "'"
    when :mut
      "~"
    when :let
      "^"
    end
    nil
  end

  def visit(node : Block)
    if node.args.empty?
      @str << "~>"
    else
      @str << "("
      node.args.each_with_index do |arg, i|
        @str << ", " if i > 0
        arg.accept self
      end
      @str << ")~>"
    end

    newline
    accept_with_indent(node.body)

    append_indent
    @str << keyword("end")

    false
  end

  def visit(node : Include)
    @str << keyword("include")
    @str << " "
    node.name.accept self
    false
  end

  def visit(node : Extend)
    @str << keyword("extend")
    @str << " "
    node.name.accept self
    false
  end

  def visit(node : And)
    # *TODO* org|"and"|"&&"
    to_s_binary node, "&&"
  end

  def visit(node : Or)
    # *TODO* org|"or"|"||"
    to_s_binary node, "||"
  end

  def visit(node : Not)
    # *TODO* org|"not"|"!"
    @str << "!"
    node.exp.accept self
    false
  end

  def visit(node : VisibilityModifier)
    node.exp.accept self
    # @str << case node.modifier
    # when Visibility::Public then ""
    # when Visibility::Private then "*"
    # when Visibility::Protected then "**"
    # else raise "I'm not aware of the visibility mode '#{node.modifier}'"
    # end
    false
  end

  def visit(node : TypeFilteredNode)
    false
  end

  def to_s_binary(node, op)
    left_needs_parens = node.left.is_a?(Assign) || node.left.is_a?(Expressions)
    in_parenthesis(left_needs_parens, node.left)

    op = case op
    when "|"
      ".|."
    when "&"
      ".&."
    when "^"
      ".^."
    else
      op
    end

    @str << " "
    @str << op
    @str << " "

    right_needs_parens = node.right.is_a?(Assign) || node.right.is_a?(Expressions) ||
                  node.right.is_a?(Call) && (node.right.as Call).name == "[]="
    in_parenthesis(right_needs_parens, node.right)
    false
  end

  def visit(node : Global)
    @str << node.name
  end

  def visit(node : LibDef)
    @str << keyword("lib")
    @str << " "
    @str << node.name
    newline
    @inside_lib = true
    accept_with_indent(node.body)
    @inside_lib = false
    append_indent
    @str << keyword("end")
    false
  end

  def visit(node : FunDef)
    if node.body
      @str << keyword("export")
    else
      @str << keyword("cfun")
    end

    @str << " "
    if node.name == node.real_name
      @str << node.name
    else
      @str << node.name
      @str << " = "
      @str << node.real_name
    end
    if node.args.size > 0
      @str << "("
      node.args.each_with_index do |arg, i|
        @str << ", " if i > 0
        if arg_name = arg.name
          @str << arg_name << " : "
        end
        arg.restriction.not_nil!.accept self
      end
      if node.varargs?
        @str << ", ..."
      end
      @str << ")"
    elsif node.varargs?
      @str << "(...)"
    end
    if node_return_type = node.return_type
      @str << " : "
      node_return_type.accept self
    end
    if body = node.body
      newline
      accept_with_indent body
      newline
      append_indent
      @str << keyword("end")
    end
    false
  end

  def visit(node : TypeDef)
    @str << keyword("ctype")
    @str << " "
    @str << node.name.to_s
    @str << " = "
    node.type_spec.accept self
    false
  end

  def visit(node : CStructOrUnionDef)
    @str << keyword(node.union? ? "union" : "struct")
    @str << " "
    @str << node.name.to_s
    newline
    @inside_struct_or_union = true
    accept_with_indent node.body
    @inside_struct_or_union = false
    append_indent
    @str << keyword("end")
    false
  end

  def visit(node : EnumDef)
    @str << keyword("type")
    @str << " "
    @str << node.name.to_s
    @str << " < "
    @str << keyword("enum")

    if base_type = node.base_type
      @str << " "
      base_type.accept self
    end

    newline

    with_indent do
      node.members.each do |member|
        append_indent
        member.accept self
        newline
      end
    end
    append_indent
    @str << keyword("end")
    false
  end

  def visit(node : RangeLiteral)
    node.from.accept self

    # *TODO* org|"..."|"til"
    # *TODO* org|".."|"to"

    if node.exclusive?
      @str << "..."
    else
      @str << ".."
    end
    node.to.accept self
    false
  end

  def visit(node : PointerOf)
    @str << keyword("pointerof")
    @str << "("
    node.exp.accept(self)
    @str << ")"
    false
  end

  def visit(node : SizeOf)
    @str << keyword("sizeof")
    @str << "("
    node.exp.accept(self)
    @str << ")"
    false
  end

  def visit(node : InstanceSizeOf)
    @str << keyword("instance_sizeof")
    @str << "("
    node.exp.accept(self)
    @str << ")"
    false
  end

  def visit(node : IsA)
    node.obj.accept self
    @str << ".of?("
    node.const.accept self
    @str << ")"
    false
  end

  def visit(node : Cast)
    accept_with_maybe_begin_end node.obj
    @str << " "
    @str << keyword("as")
    @str << " "
    node.to.accept self
    false
  end

  def visit(node : NilableCast)
    accept_with_maybe_begin_end node.obj
    @str << " "
    @str << keyword("as?")
    @str << " "
    node.to.accept self
    false
  end

  def visit(node : RespondsTo)
    node.obj.accept self
    @str << ".implements?(" << node.name << ")"
    false
  end

  def visit(node : Require)
    @str << keyword("require")
    @str << " \""
    @str << node.string
    @str << "\""
    false
  end

  def visit(node : Case)
    if cond = node.cond
      @str << keyword("match")
      @str << " "
      cond.accept self
    else
      @str << keyword("cond")
    end
    newline

    # *TODO* org|Indented|"when"
    node.whens.each do |wh|
      wh.accept self
    end
    if node_else = node.else
      append_indent

      # *TODO* org|"*"|"else"
      @str << keyword("else")
      newline
      accept_with_indent node_else
    end
    append_indent
    @str << keyword("end")
    false
  end

  def visit(node : When)
    append_indent
    @str << keyword("when")
    @str << " "
    node.conds.each_with_index do |cond, i|
      @str << ", " if i > 0
      cond.accept self
    end
    newline
    accept_with_indent node.body
    false
  end

  def visit(node : Select)
    @str << keyword("select")
    newline
    node.whens.each do |a_when|
      @str << "when "
      a_when.condition.accept self
      newline
      accept_with_indent a_when.body
    end
    if a_else = node.else
      @str << "else"
      newline
      accept_with_indent a_else
    end
    @str << keyword("end")
    newline
    false
  end

  def visit(node : ImplicitObj)
    false
  end

  def visit(node : ExceptionHandler)
    @str << keyword("try")
    newline

    accept_with_indent node.body

    node.rescues.try &.each do |a_rescue|
      append_indent
      a_rescue.accept self
    end

    if node_else = node.else
      append_indent
      @str << keyword("fulfil")
      newline
      accept_with_indent node_else
    end

    if node_ensure = node.ensure
      append_indent
      @str << keyword("ensure")
      newline
      accept_with_indent node_ensure
    end

    append_indent
    @str << keyword("end")
    false
  end

  def visit(node : Rescue)
    @str << keyword("rescue")
    if name = node.name
      @str << " "
      @str << name
    end
    if (types = node.types) && types.size > 0
      if node.name
        @str << " :"
      end
      @str << " "
      types.each_with_index do |type, i|
        @str << " | " if i > 0
        type.accept self
      end
    end
    newline
    accept_with_indent node.body
    false
  end

  def visit(node : Alias)
    @str << keyword("alias")
    @str << " "
    @str << node.name
    @str << " = "
    node.value.accept self
    false
  end

  def visit(node : TypeOf)
    @str << keyword("typeof")
    @str << "("
    node.expressions.each_with_index do |exp, i|
      @str << ", " if i > 0
      exp.accept self
    end
    @str << ")"
    false
  end

  def visit(node : Attribute)
    @str << "'"
    @str << node.name
    if !node.args.empty? || node.named_args
      @str << "("
      printed_arg = false
      node.args.each_with_index do |arg, i|
        @str << ", " if i > 0
        arg.accept self
        printed_arg = true
      end
      if named_args = node.named_args
        @str << ", " if printed_arg
        named_args.each do |named_arg|
          visit_named_arg_name(named_arg.name)
          @str << ": "
          named_arg.value.accept self
          printed_arg = true
        end
      end
      @str << ")"
    end
    false
  end

  def visit(node : MagicConstant)
    @str << node.name
  end

  def visit(node : Asm)
    node.text.inspect(@str)
    @str << " :"
    if output = node.output
      @str << " "
      output.accept self
      @str << " "
    end
    @str << ":"
    if inputs = node.inputs
      @str << " "
      inputs.each_with_index do |input, i|
        @str << ", " if i > 0
        input.accept self
      end
    end
    if clobbers = node.clobbers
      @str << " : "
      clobbers.each_with_index do |clobber, i|
        @str << ", " if i > 0
        clobber.inspect(@str)
      end
    end
    if node.volatile? || node.alignstack? || node.intel?
      @str << " : "
      comma = false
      if node.volatile?
        @str << %("volatile")
        comma = true
      end
      if node.alignstack?
        @str << ", " if comma
        @str << %("alignstack")
        comma = true
      end
      if node.intel?
        @str << ", " if comma
        @str << %("intel")
        comma = true
      end
    end
    false
  end

  def visit(node : AsmOperand)
    node.constraint.inspect(@str)
    @str << '('
    node.exp.accept self
    @str << ')'
    false
  end

  def visit(node : FileNode)
    @str.puts
    @str << "-- " << node.filename
    @str.puts
    node.node.accept self
    false
  end

  def visit(node : YieldBlockBinder)
    false
  end

  def newline
    @str << "\n"
  end

  def indent_string
    "  "
  end

  def append_indent
    @indent.times do
      @str << indent_string
    end
  end

  def with_indent
    @indent += 1
    yield
    @indent -= 1
  end

  def accept_with_indent(node : Expressions)
    with_indent do
      node.accept self
    end
  end

  def accept_with_indent(node : Nop)
  end

  def accept_with_indent(node : ASTNode)
    with_indent do
      append_indent
      node.accept self
    end
    newline
  end

  def accept_with_maybe_begin_end(node)
    if node.is_a?(Expressions)
      if node.expressions.size == 1
        @str << "("
        node.expressions.first.accept self
        @str << ")"
      else
        @str << keyword("do") # *TODO* this doubling of function of "do" as "=>" AND "do–block", hmmmm
        newline
        accept_with_indent(node)
        append_indent
        @str << keyword("end")
      end
    else
      node.accept self
    end
  end

  def inside_macro
    @inside_macro += 1
    yield
    @inside_macro -= 1
  end

  def to_s
    @str.to_s
  end

  def to_s(io)
    @str.to_s(io)
  end
end

end # module

require "./stylize_onyx"
