# frozen_string_literal: true

module DeadCode
  MAIN = "(main)" # owner of top-level `def`s (rake files, scripts)

  Location = Struct.new(:path, :line) do
    def to_s = "#{path}:#{line}"
  end

  # A class or module. Reopened constants (monkey patches, split files) share one entry.
  class Namespace
    attr_reader :fqn, :kind, :locations, :flags
    attr_accessor :superclass_ref # [path, nesting] of the first `class X < Y` seen

    def initialize(fqn, kind)
      @fqn = fqn
      @kind = kind
      @locations = []
      @flags = Set.new
    end

    def last_segment = fqn.split("::").last
    def label = fqn
  end

  class MethodDef
    attr_reader :owner, :name, :singleton, :locations
    attr_accessor :visibility, :in_block

    def initialize(owner, name, singleton, visibility, in_block)
      @owner = owner
      @name = name
      @singleton = singleton
      @visibility = visibility
      @in_block = in_block
      @locations = []
    end

    def key = self.class.key(owner, name, singleton)
    def label = key
    def public? = visibility == :public

    def self.key(owner, name, singleton) = "#{owner}#{singleton ? "." : "#"}#{name}"
  end

  # Everything referenced from one scope: the top level ("root"), a class/module body
  # ("C:Foo::Bar") or a method body ("M:Foo::Bar#baz"). Liveness flows through scopes.
  class ScopeRefs
    attr_reader :names, :self_calls, :symbols, :consts, :const_strings, :normalized_consts,
                :method_patterns, :const_patterns, :descendant_roots

    def initialize
      @names = Set.new             # method calls and identifier-like strings
      @self_calls = Set.new        # `foo` / `self.foo` - calls that can only hit this object
      @symbols = Set.new           # :foo / foo: — also imply `foo=` (mass assignment)
      @consts = Set.new            # [path, nesting] resolved lexically
      @const_strings = Set.new     # "Foo::Bar" in strings/templates/YAML, suffix-matched
      @normalized_consts = Set.new # inferred by convention (has_many :foos => Foo)
      @method_patterns = Set.new   # send("foo_#{x}") => /\Afoo_.+\z/
      @const_patterns = Set.new    # "#{x}_importer".camelize.constantize
      @descendant_roots = Set.new  # [path, nesting] of Foo.descendants / Foo.subclasses
    end
  end

  class Index
    attr_reader :namespaces, :methods, :scopes, :test_refs, :test_blocks, :stats, :warnings, :visibility_overrides

    def initialize
      @namespaces = {}
      @methods = {}
      @scopes = {}
      @test_refs = ScopeRefs.new
      @test_blocks = [] # root TestBlocks of every test file
      @stats = Hash.new(0)
      @warnings = []
      @visibility_overrides = {}
    end

    def namespace!(fqn, kind, location)
      ns = (@namespaces[fqn] ||= Namespace.new(fqn, kind))
      ns.locations << location
      ns
    end

    def method!(owner, name, singleton, visibility, location, in_block:)
      key = MethodDef.key(owner, name, singleton)
      m = (@methods[key] ||= MethodDef.new(owner, name, singleton, visibility, in_block))
      m.visibility = :public if visibility == :public # reopened as public anywhere => public
      m.locations << location
      m
    end

    def scope(key) = (@scopes[key] ||= ScopeRefs.new)

    # `private :foo` / `private_class_method :foo` applied after all files are read.
    def apply_visibility_overrides!
      @visibility_overrides.each do |key, visibility|
        @methods[key]&.visibility = visibility
      end
    end
  end
end
