# frozen_string_literal: true

module Deadspace
  # Walks one Ruby file's Prism AST and records definitions (classes, modules, methods)
  # and every reference (calls, symbols, constants, strings) attributed to the scope it
  # appears in, so the analyzer can propagate liveness from entry points.
  #
  # Modes:
  #   :source    - definitions are indexed, references are scoped (app/, lib/, config/)
  #   :reference - everything counts as live top-level code, nothing is indexed (scripts)
  #   :test      - references go to the test bucket only (spec/, test/)
  class RubyVisitor < Prism::Visitor
    VISIBILITY_KEYWORDS = %i[private protected public module_function].freeze
    VISIBILITY_WITH_ARGS = %i[private protected public module_function private_class_method
                              public_class_method private_constant public_constant].freeze
    DISPATCH_METHODS = %i[send public_send __send__ try try! respond_to? method public_method
                          instance_method define_method].freeze
    CONSTANTIZE_METHODS = %i[constantize safe_constantize const_get classify camelize].freeze
    ASSOCIATIONS = %i[has_many has_one belongs_to has_and_belongs_to_many].freeze
    IDENT_RE = /\A[a-z_][a-zA-Z0-9_]*[?!=]?\z/
    CONST_RE = /\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*\z/
    PATTERN_STATIC_RE = %r{\A[\w:?!=/]*\z}

    def initialize(index, path, mode:, collect_symbols: true, collect_strings: true, top_scope: "root")
      super()
      @index = index
      @path = path
      @mode = mode
      @collect_symbols = collect_symbols
      @collect_strings = collect_strings
      @nesting = []
      @nesting_snapshot = [].freeze
      @scope_stack = [mode == :test ? :test : top_scope]
      @visibility_stack = [:public]
      @singleton_stack = [false]
      @block_stack = [nil] # innermost DSL block (`included do`) of the current class body
      @def_stack = []
    end

    def visit_class_node(node) = enter_namespace(node, :class)
    def visit_module_node(node) = enter_namespace(node, :module)

    def visit_singleton_class_node(node)
      return super unless node.expression.is_a?(Prism::SelfNode)

      with_frame(singleton: true) { node.body&.accept(self) }
    end

    def visit_def_node(node)
      if node.receiver && !node.receiver.is_a?(Prism::SelfNode)
        return super # `def obj.foo` - can't attribute it, but still scan the body
      end

      singleton = node.receiver.is_a?(Prism::SelfNode) || @singleton_stack.last
      define_method_scope(node.name.to_s, singleton, node.location.start_line) do
        node.parameters&.accept(self)
        node.body&.accept(self)
      end
    end

    def visit_call_node(node)
      name = node.name
      args = node.arguments&.arguments || []
      receiverless = node.receiver.nil?

      return if receiverless && VISIBILITY_WITH_ARGS.include?(name) && handle_visibility(name, args)
      return if receiverless && name == :define_method && handle_define_method(node, args)
      return if receiverless && name == :alias_method && handle_alias_method(args, node.location.start_line)
      return if receiverless && name == :scope && handle_scope_macro(node, args)

      association_convention(args) if receiverless && ASSOCIATIONS.include?(name)
      args.each { |arg| record_pattern(arg, refs.method_patterns) } if DISPATCH_METHODS.include?(name)
      record_constantize_pattern(node.receiver) if CONSTANTIZE_METHODS.include?(name)
      if %i[const_get const_defined? const_source_location].include?(name)
        args.each do |arg|
          record_pattern(arg, refs.const_patterns)
        end
      end
      record_descendant_root(node.receiver) if %i[descendants subclasses].include?(name)
      if name == :abstract_class= && node.receiver.is_a?(Prism::SelfNode) && @nesting.any?
        @index.namespaces[@nesting.last]&.flags&.add(:abstract)
      end

      refs.names << name.to_s
      refs.self_calls << name.to_s if receiverless || node.receiver.is_a?(Prism::SelfNode)
      node.receiver&.accept(self)
      node.arguments&.accept(self)
      visit_block(node.block, name)
    end

    def visit_alias_method_node(node)
      new_name = node.new_name
      old_name = node.old_name
      return super unless new_name.is_a?(Prism::SymbolNode) && old_name.is_a?(Prism::SymbolNode)

      define_alias(new_name.unescaped, old_name.unescaped, node.location.start_line)
    end

    def visit_super_node(node)
      refs.names << @def_stack.last if @def_stack.any?
      super
    end

    def visit_forwarding_super_node(node)
      refs.names << @def_stack.last if @def_stack.any?
      super
    end

    def visit_call_operator_write_node(node) = record_call_write(node) { super }
    def visit_call_or_write_node(node) = record_call_write(node) { super }
    def visit_call_and_write_node(node) = record_call_write(node) { super }

    def visit_symbol_node(node)
      refs.symbols << node.unescaped if @collect_symbols
    end

    def visit_string_node(node)
      return unless @collect_strings

      value = node.unescaped
      return if value.length > 150 || !value.valid_encoding?

      if value.match?(IDENT_RE)
        refs.names << value
      elsif value.match?(CONST_RE)
        refs.const_strings << value.delete_prefix("::")
      end
    end

    def visit_interpolated_symbol_node(node)
      record_pattern(node, refs.method_patterns)
      super
    end

    def visit_constant_read_node(node)
      record_const(node.name.to_s)
    end

    def visit_constant_path_node(node)
      record_const(node.full_name)
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
      node.parent&.accept(self)
      record_const(node.name.to_s)
    end

    # `Foo::BAR = 1` - the target is a definition, only the value holds references.
    def visit_constant_path_write_node(node) = node.value.accept(self)
    def visit_constant_path_or_write_node(node) = node.value.accept(self)

    # `Contact = Struct.new(:id) do ... end` / `Error = Class.new(StandardError)` define a class.
    def visit_constant_write_node(node)
      call = node.value
      kind = anonymous_namespace_kind(call)
      return node.value.accept(self) unless kind

      fqn = @nesting.empty? ? node.name.to_s : "#{@nesting.last}::#{node.name}"
      if source?
        ns = @index.namespace!(fqn, kind, Location.new(@path, node.location.start_line))
        base = call.receiver.name == :Class && call.arguments&.arguments&.first
        path = base && constant_path_string(base)
        ns.superclass_ref ||= [path, @nesting_snapshot] if path
      end
      push_scope("C:#{fqn}") do
        call.arguments&.accept(self)
        with_frame(singleton: false, nesting: fqn) { call.block&.body&.accept(self) }
      end
    end

    private

    def refs
      key = @scope_stack.last
      key == :test ? @index.test_refs : @index.scope(key)
    end

    def source? = @mode == :source

    def push_scope(key)
      @scope_stack.push(source? ? key : @scope_stack.last)
      yield
    ensure
      @scope_stack.pop
    end

    def with_frame(singleton:, nesting: nil)
      if nesting
        @nesting.push(nesting)
        @nesting_snapshot = @nesting.dup.freeze
      end
      @visibility_stack.push(:public)
      @singleton_stack.push(singleton)
      @block_stack.push(nil)
      yield
    ensure
      @block_stack.pop
      @singleton_stack.pop
      @visibility_stack.pop
      if nesting
        @nesting.pop
        @nesting_snapshot = @nesting.dup.freeze
      end
    end

    def current_owner = @nesting.last || MAIN

    ANONYMOUS_NAMESPACES = { %i[Struct new] => :class, %i[Class new] => :class, %i[Data define] => :class,
                             %i[Module new] => :module }.freeze

    def anonymous_namespace_kind(call)
      return unless call.is_a?(Prism::CallNode) && call.receiver.is_a?(Prism::ConstantReadNode)

      ANONYMOUS_NAMESPACES[[call.receiver.name, call.name]]
    end

    def enter_namespace(node, kind)
      fqn = definition_fqn(node.constant_path)
      return visit_child_nodes(node) unless fqn

      if source?
        ns = @index.namespace!(fqn, kind, Location.new(@path, node.location.start_line))
        superclass = kind == :class && node.superclass
        if superclass && ns.superclass_ref.nil? && (path = constant_path_string(superclass))
          ns.superclass_ref = [path, @nesting_snapshot]
        end
      end

      push_scope("C:#{fqn}") do
        node.superclass&.accept(self) if kind == :class
        with_frame(singleton: false, nesting: fqn) { node.body&.accept(self) }
      end
    end

    def definition_fqn(constant_path)
      path = constant_path_string(constant_path)
      return unless path
      return path.delete_prefix("::") if path.start_with?("::")

      @nesting.empty? ? path : "#{@nesting.last}::#{path}"
    end

    def constant_path_string(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then node.full_name
      end
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
      nil
    end

    def current_visibility(singleton)
      return :public if singleton

      @pending_visibility || (@visibility_stack.last == :module_function ? :public : @visibility_stack.last)
    end

    def register_method(name, singleton, line)
      return unless source?

      singleton ||= @block_stack.last == "class_methods"
      @index.method!(current_owner, name, singleton, current_visibility(singleton),
                     Location.new(@path, line), in_block: @block_stack.last)
    end

    def define_method_scope(name, singleton, line, &)
      method = register_method(name, singleton, line)
      key = method ? "M:#{method.key}" : @scope_stack.last
      @def_stack.push(name)
      @block_stack.push(nil)
      push_scope(key, &)
    ensure
      @block_stack.pop
      @def_stack.pop
    end

    def visit_block(block, call_name)
      return block&.accept(self) unless block.is_a?(Prism::BlockNode)

      @block_stack.push(call_name.to_s)
      @singleton_stack.push(true) if call_name == :class_methods
      block.accept(self)
    ensure
      @singleton_stack.pop if call_name == :class_methods && block.is_a?(Prism::BlockNode)
      @block_stack.pop if block.is_a?(Prism::BlockNode)
    end

    # Returns true when the call was fully handled (its symbol args are not references).
    def handle_visibility(name, args)
      if args.empty?
        @visibility_stack[-1] = name if VISIBILITY_KEYWORDS.include?(name)
        return true
      end

      args.each do |arg|
        case arg
        when Prism::DefNode
          @pending_visibility = name if VISIBILITY_KEYWORDS.include?(name) && name != :module_function
          arg.accept(self)
          @pending_visibility = nil
        when Prism::SymbolNode, Prism::StringNode
          record_visibility_override(name, arg.unescaped)
        when Prism::ArrayNode
          arg.elements.each { |e| record_visibility_override(name, e.unescaped) if e.respond_to?(:unescaped) }
        else
          arg.accept(self) # e.g. `private attr_reader :foo`
        end
      end
      true
    end

    def record_visibility_override(keyword, method_name)
      return unless source?

      visibility, singleton =
        case keyword
        when :private, :protected, :public then [keyword, false]
        when :private_class_method then [:private, true]
        when :public_class_method then [:public, true]
        else return
        end
      @index.visibility_overrides[MethodDef.key(current_owner, method_name, singleton)] = visibility
    end

    def handle_define_method(node, args)
      name_node = args.first
      return false unless name_node.is_a?(Prism::SymbolNode) || name_node.is_a?(Prism::StringNode)

      define_method_scope(name_node.unescaped, @singleton_stack.last, node.location.start_line) do
        args.drop(1).each { |a| a.accept(self) }
        node.block&.accept(self)
      end
      true
    end

    def handle_alias_method(args, line)
      new_name, old_name = args
      literal = ->(n) { n.is_a?(Prism::SymbolNode) || n.is_a?(Prism::StringNode) }
      return false unless args.size == 2 && literal.call(new_name) && literal.call(old_name)

      define_alias(new_name.unescaped, old_name.unescaped, line)
      true
    end

    def define_alias(new_name, old_name, line)
      define_method_scope(new_name, @singleton_stack.last, line) { refs.names << old_name }
    end

    # `scope :active, -> { ... }` defines a class method; its lambda runs when it is called.
    def handle_scope_macro(node, args)
      name_node = args.first
      return false unless name_node.is_a?(Prism::SymbolNode) && @nesting.any?

      define_method_scope(name_node.unescaped, true, node.location.start_line) do
        args.drop(1).each { |a| a.accept(self) }
        node.block&.accept(self)
      end
      true
    end

    def association_convention(args)
      name_node = args.first
      return unless name_node.is_a?(Prism::SymbolNode)

      refs.normalized_consts << Deadspace.normalize(name_node.unescaped.singularize)
    end

    def record_call_write(node)
      refs.names << node.read_name.to_s << node.write_name.to_s
      yield
    end

    def record_const(path)
      refs.consts << [path, @nesting_snapshot]
    end

    def record_descendant_root(receiver)
      case receiver
      when Prism::SelfNode, nil
        refs.descendant_roots << ["::#{@nesting.last}", []] if @nesting.any?
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        path = constant_path_string(receiver)
        refs.descendant_roots << [path, @nesting_snapshot] if path
      end
    end

    # "#{type}_importer".camelize.constantize / "Importers::#{name}".safe_constantize
    def record_constantize_pattern(receiver)
      node = receiver
      node = node.receiver while node.is_a?(Prism::CallNode) && node.receiver
      record_pattern(node, refs.const_patterns)
    end

    def record_pattern(node, target)
      return unless node.is_a?(Prism::InterpolatedStringNode) || node.is_a?(Prism::InterpolatedSymbolNode)

      static = node.parts.select { |p| p.is_a?(Prism::StringNode) }.map(&:unescaped)
      return if static.empty? || static.sum(&:length) < 3
      return unless static.all? { |s| s.valid_encoding? && s.match?(PATTERN_STATIC_RE) }

      body = node.parts.map { |p| p.is_a?(Prism::StringNode) ? Regexp.escape(p.unescaped) : ".+" }.join
      target << "\\A#{body.delete_prefix("::")}\\z"
    end
  end
end
