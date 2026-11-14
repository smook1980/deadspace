# frozen_string_literal: true

module Deadspace
  # One RSpec example group / example, or Minitest test class / test, with its line range, what it
  # describes, and what its own code references (children excluded).
  class TestBlock
    attr_reader :path, :first_line, :last_line, :kind, :const_path, :method_name, :method_scope,
                :parent, :children, :names, :consts, :local_defs
    attr_accessor :whole_file # the file holds nothing else: delete the file, not just these lines

    def initialize(path:, first_line:, last_line:, kind:, parent:, const_path: nil, method_name: nil, method_scope: nil)
      @path = path
      @first_line = first_line
      @last_line = last_line
      @kind = kind                 # :group or :example
      @const_path = const_path     # RSpec.describe Foo::Bar / class Foo::BarTest
      @method_name = method_name   # describe "#foo" / ".foo" / :foo
      @method_scope = method_scope # :instance, :singleton, or nil when the descriptor doesn't say
      @parent = parent
      @children = []
      @names = Set.new             # calls and symbols (`get :archive`, `its(:title)`)
      @consts = Set.new            # constant paths and constant-like strings
      @local_defs = Set.new        # helpers defined in the spec (`def x`, `let(:x)`, `subject(:x)`)
      @whole_file = false
    end

    def example? = kind == :example
    def contains?(other) = path == other.path && first_line <= other.first_line && last_line >= other.last_line
    def ancestors = parent ? [parent] + parent.ancestors : []

    # True when `name` inside this block calls a spec helper rather than the code under test.
    def helper?(name) = local_defs.include?(name) || parent&.helper?(name) || false
  end

  # Builds the TestBlock tree for one test file.
  class TestMapVisitor < Prism::Visitor
    GROUPS = %i[describe context feature shared_examples shared_examples_for shared_context example_group
                xdescribe xcontext fdescribe fcontext].freeze
    EXAMPLES = %i[it specify example scenario its test fit fspecify fexample xit xspecify xexample].freeze
    METHOD_DESCRIPTOR_RE = /\A(#|\.|::)([a-z_]\w*[?!=]?)(?:\s|\z)/
    BARE_METHOD_RE = /\A[a-z_]\w*[?!=]?\z/
    REQUIRE_CALLS = %i[require require_relative].freeze

    attr_reader :roots

    def initialize(path, line_count)
      super()
      @path = path
      @line_count = line_count
      @roots = []
      @stack = []
    end

    def visit_program_node(node)
      super
      statements = node.statements.body.reject { |s| s.is_a?(Prism::CallNode) && REQUIRE_CALLS.include?(s.name) }
      return unless statements.size == 1 && @roots.size == 1 && covers?(@roots.first, statements.first)

      @roots.first.whole_file = @line_count
    end

    # Calls are recorded on the innermost block, so an example only "calls" what its own body calls.
    def visit_call_node(node)
      unless node.block.is_a?(Prism::BlockNode) && (node.receiver.nil? || rspec_receiver?(node.receiver)) &&
             (GROUPS.include?(node.name) || EXAMPLES.include?(node.name))
        current&.names&.add(node.name.to_s)
        record_helper(node)
        return super
      end

      if GROUPS.include?(node.name)
        group(node)
      elsif EXAMPLES.include?(node.name)
        args = node.arguments&.arguments || []
        args.each { |a| a.accept(self) } # its(:title)
        with_block(node, :example) { node.block.accept(self) }
      end
    end

    # Minitest: class PostTest < ActiveSupport::TestCase / def test_publishes
    def visit_class_node(node)
      path = constant_path(node.constant_path)
      return super unless path&.end_with?("Test")

      with_block(node, :group, const_path: path.delete_suffix("Test")) { node.body&.accept(self) }
    end

    def visit_def_node(node)
      current&.local_defs&.add(node.name.to_s) unless node.name.start_with?("test_")
      return super unless node.name.start_with?("test_") && @stack.any?

      with_block(node, :example) { node.body&.accept(self) }
    end

    def visit_symbol_node(node) = current&.names&.add(node.unescaped)

    def visit_string_node(node)
      value = node.unescaped
      current&.consts&.add(value.delete_prefix("::")) if value.valid_encoding? && value.match?(RubyVisitor::CONST_RE)
    end

    def visit_constant_read_node(node) = current&.consts&.add(node.name.to_s)

    def visit_constant_path_node(node)
      current&.consts&.add(node.full_name.delete_prefix("::"))
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
      super
    end

    private

    def current = @stack.last

    HELPER_MACROS = %i[let let! subject subject!].freeze

    def record_helper(node)
      return unless node.receiver.nil? && HELPER_MACROS.include?(node.name)

      name = node.arguments&.arguments&.first
      current&.local_defs&.add(name.unescaped) if name.is_a?(Prism::SymbolNode)
    end

    def group(node)
      args = node.arguments&.arguments || []
      const_path = nil
      method_name = nil
      method_scope = nil
      args.each do |arg|
        case arg
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          const_path ||= constant_path(arg)
        when Prism::StringNode
          method_name, method_scope = method_descriptor(arg.unescaped) unless method_name
        when Prism::SymbolNode
          method_name ||= arg.unescaped
        end
      end
      with_block(node, :group, const_path:, method_name:, method_scope:) do
        args.each { |a| a.accept(self) unless a.is_a?(Prism::StringNode) }
        node.block.accept(self)
      end
    end

    def method_descriptor(text)
      if (m = text.match(METHOD_DESCRIPTOR_RE))
        [m[2], m[1] == "#" ? :instance : :singleton]
      elsif text.match?(BARE_METHOD_RE)
        [text, nil]
      end
    end

    def with_block(node, kind, **descriptor)
      block = TestBlock.new(path: @path, first_line: node.location.start_line, last_line: node.location.end_line,
                            kind:, parent: current, **descriptor)
      current ? current.children << block : @roots << block
      @stack.push(block)
      yield
    ensure
      @stack.pop
    end

    def covers?(block, node) = block.first_line == node.location.start_line && block.last_line == node.location.end_line

    def rspec_receiver?(node) = node.is_a?(Prism::ConstantReadNode) && node.name == :RSpec

    def constant_path(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then node.full_name.delete_prefix("::")
      end
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
      nil
    end
  end
end
