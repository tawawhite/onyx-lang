require "./program"
require "./syntax/ast"
require "./syntax/visitor"
require "./semantic/*"

# The overall algorithm for semantic analysis of a program is:
# - top level: declare clases, modules, macros, defs and other top-level stuff
# - new methods: create `new` methods for every `initialize` method
# - type declarations: process type declarations like `@x : Int32`
# - check abstract defs: check that abstract defs are implemented
# - class_vars_initializers (ClassVarsInitializerVisitor): process initializers like `@@x = 1`
# - instance_vars_initializers (InstanceVarsInitializerVisitor): process initializers like `@x = 1`
# - main: process "main" code, calls and method bodies (the whole program).
# - cleanup: remove dead code and other simplifications
# - check recursive structs (RecursiveStructChecker): check that structs are not recursive (impossible to codegen)

class Crystal::Program
  # Runs semantic analysis on the given node, returning a node
  # that's typed. In the process types and methods are defined in
  # this program.
  def semantic(node : ASTNode, stats = false) : ASTNode
    node, processor = top_level_semantic(node, stats: stats)

    _dbg_overview "\nSemantic: cvars initializers:\n\n".white
    Crystal.timing("Semantic (cvars initializers)", stats) do
      visit_class_vars_initializers(node)
    end

    # Check that class vars without an initializer are nilable,
    # give an error otherwise
    _dbg_overview "\nSemantic: Check non-nil type scoped variables:\n\n".white
    processor.check_non_nilable_class_vars_without_initializers

    _dbg_overview "\nSemantic: ivars initializers:\n\n".white
    Crystal.timing("Semantic (ivars initializers)", stats) do
      node.accept InstanceVarsInitializerVisitor.new(self)
    end

    _dbg_overview "\nSemantic: main:\n\n".white
    result = Crystal.timing("Semantic (main)", stats) do
      visit_main(node)
    end

    _dbg_overview "\nSemantic: cleanup:\n\n".white
    Crystal.timing("Semantic (cleanup)", stats) do
      cleanup_types
      cleanup_files
    end

    _dbg_overview "\nSemantic: recursive struct check:\n\n".white
    Crystal.timing("Semantic (recursive struct check)", stats) do
      RecursiveStructChecker.new(self).run
    end

    _dbg_overview "\nType-inference stages completed:\n\n".white
    result
  end



  # Processes type declarations and instance/class/global vars
  # types are guessed or followed according to type annotations.
  #
  # This alone is useful for some tools like doc or hierarchy
  # where a full semantic of the program is not needed.
  def top_level_semantic(node, stats = false)
    _dbg_overview "\nSemantic: Onyx-specific: program wide pragmas:\n\n".white
    Crystal.timing("Semantic (program wide pragmas)", stats) do
      visit_program_wide_pragmas(node)
    end

    _dbg_overview "\nSemantic: top level:\n\n".white
    new_expansions = Crystal.timing("Semantic (top level)", stats) do
      visitor = TopLevelVisitor.new(self)
      node.accept visitor
      visitor.new_expansions
    end

    # *TODO* might be completely pointess really, simply dive each time...
    _dbg_overview "\nSemantic: Onyx-specific: lift out type extends:\n\n".white
    Crystal.timing("Semantic (lift out type extends)", stats) do
      node.transform LiftOutExtendsTransformer.new
    end

    _dbg_overview "\nSemantic: new:\n\n".white
    Crystal.timing("Semantic (new)", stats) do
      define_new_methods(new_expansions)
    end

    _dbg_overview "\nSemantic: type declarations:\n\n".white
    node, processor = Crystal.timing("Semantic (type declarations)", stats) do
      TypeDeclarationProcessor.new(self).process(node)
    end

    _dbg_overview "\nSemantic: abstract def check:\n\n".white
    Crystal.timing("Semantic (abstract def check)", stats) do
      AbstractDefChecker.new(self).run
    end

    {node, processor}
  end


  # class PropagateDocVisitor < Visitor
  #   @doc : String
  #
  #   def initialize(@doc)
  #   end
  #
  #   def visit(node : Expressions)
  #     true
  #   end
  #
  #   def visit(node : ClassDef | ModuleDef | EnumDef | Def | FunDef | Alias | Assign)
  #     node.doc ||= @doc
  #     false
  #   end
  #
  #   def visit(node : ASTNode)
  #     true
  #   end
  # end


  # *TODO* *MOVE* *POS*
  # *TODO* might be completely pointess really, simply dive each time...
  # def lift_out_type_extensions(node)
  #   node.transform LiftOutExtendsTransformer.new
  # end

  class LiftOutExtendsTransformer < Transformer
    def initialize()
    end

    def transform(node : ExtendTypeDef) : ASTNode
      if exp = node.expanded
        exp
      else
        raise "SHOULD NOT HAPPEN! found extend type that hasn't been expanded!"
      end
    end
  end

end
