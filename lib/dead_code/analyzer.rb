# frozen_string_literal: true

module DeadCode
  # `targets` is what the finding covers (constant names, or the MethodDef); `tests` the removable test blocks.
  Finding = Struct.new(:confidence, :kind, :name, :location, :reason, :referenced_in_tests,
                       :definition_count, :targets, :tests, keyword_init: true)

  # Lines of a test file that only exist to test a finding. match is :describes (the group is about
  # the finding: `describe "#foo"`, `RSpec.describe Foo`) or :calls (an example whose body calls it).
  TestRemoval = Struct.new(:path, :first_line, :last_line, :match, :whole_file, keyword_init: true) do
    def lines = first_line == last_line ? first_line.to_s : "#{first_line}-#{last_line}"
    def to_s = "#{path}:#{lines}"
  end

  # Reachability over scopes. Entry points (top-level code, routed controller actions, framework
  # hooks, boot-time files, library namespaces) are live; a scope's references make the classes and
  # methods they name live; repeat until nothing changes. Whatever is left was never reached from
  # an entry point. Method matching is by name (no type inference), so it errs towards "used".
  class Analyzer
    CONVENTION_SYMBOL_SUFFIXES = %w[validator input policy].freeze # validates x, foo: / as: :foo / authorize :foo
    CONVENTION_CLASS_SUFFIX_RE =
      /_(observer|job|worker|mailer|serializer|decorator|policy|channel|component|presenter|service|validator|input)\z/
    INFERRED_COMPANION_RE = /\A(.+)(Decorator|Serializer|Presenter)\z/
    KIND_ORDER = { module: 0, class: 1, controller_action: 2, method: 3 }.freeze
    METAPROGRAMMING_BLOCKS = %w[included extended prepended class_methods class_eval class_exec instance_eval
                                instance_exec module_eval module_exec new concerning tap then each].freeze

    attr_reader :findings

    def initialize(index, routes, config, gem_namespaces: Set.new)
      @index = index
      @routes = routes
      @config = config
      @gem_namespaces = gem_namespaces
      @namespaces = index.namespaces
    end

    def run
      build_lookups
      resolve_inheritance
      map_routes
      seed
      propagate
      @findings = classify.sort_by do |f|
        [f.confidence == :unused ? 0 : 1, KIND_ORDER.fetch(f.kind), f.location.path, f.location.line]
      end
      attach_tests(@findings)
      @findings
    end

    private

    # ---------------------------------------------------------------- lookups

    def build_lookups
      @ns_by_last = Hash.new { |h, k| h[k] = [] }
      @ns_by_norm_last = Hash.new { |h, k| h[k] = [] }
      @ns_by_norm_full = Hash.new { |h, k| h[k] = [] }
      @namespaces.each_key do |fqn|
        last = fqn.split("::").last
        @ns_by_last[last] << fqn
        @ns_by_norm_last[DeadCode.normalize(last)] << fqn
        @ns_by_norm_full[DeadCode.normalize(fqn)] << fqn
      end
      @methods_by_name = Hash.new { |h, k| h[k] = [] }
      @methods_by_owner = Hash.new { |h, k| h[k] = [] }
      @index.methods.each_value do |m|
        @methods_by_name[m.name] << m
        @methods_by_owner[m.owner] << m
      end
    end

    def parent_ns(fqn)
      parts = fqn.split("::")
      while parts.size > 1
        parts.pop
        candidate = parts.join("::")
        return candidate if @namespaces.key?(candidate)
      end
      nil
    end

    # Lexical lookup first (Module.nesting), then top level, then any constant whose path ends
    # with the reference (covers lookups through ancestors and compact `class A::B` nesting).
    def resolve(path, nesting)
      if path.start_with?("::")
        path = path.delete_prefix("::")
        return @namespaces.key?(path) ? [path] : suffix_match(path)
      end
      nesting.reverse_each do |outer|
        candidate = "#{outer}::#{path}"
        return [candidate] if @namespaces.key?(candidate)
      end
      return [path] if @namespaces.key?(path)

      suffix_match(path)
    end

    # `Foo::BAR` and `Foo::Bar.baz` name a value constant we don't index; the namespace holding it
    # is what is referenced, so retry with the last segment dropped until something resolves.
    def resolve_prefix(path, nesting)
      loop do
        found = nesting ? resolve(path, nesting) : suffix_match(path.delete_prefix("::"))
        return found if found.any?

        cut = path.rindex("::")
        return [] if cut.nil? || cut.zero?

        path = path[0...cut]
      end
    end

    def suffix_match(path)
      @ns_by_last[path.split("::").last].select { |fqn| fqn == path || fqn.end_with?("::#{path}") }
    end

    # ---------------------------------------------------------------- inheritance

    def resolve_inheritance
      @superclass = {}
      @external_superclass = {}
      @subclasses = Hash.new { |h, k| h[k] = [] }
      @namespaces.each_value do |ns|
        next unless ns.superclass_ref

        path, nesting = ns.superclass_ref
        target = resolve(path, nesting).reject { |fqn| fqn == ns.fqn }.first
        if target
          @superclass[ns.fqn] = target
          @subclasses[target] << ns.fqn
        else
          @external_superclass[ns.fqn] = path.delete_prefix("::")
        end
      end
    end

    def ancestors(fqn)
      chain = []
      while (fqn = @superclass[fqn]) && !chain.include?(fqn)
        chain << fqn
      end
      chain
    end

    # The first base class outside the app, e.g. "ActiveRecord::Base".
    def external_base(fqn) = ([fqn] + ancestors(fqn)).filter_map { |c| @external_superclass[c] }.first

    def descendants(fqn, acc = Set.new)
      @subclasses[fqn].each { |child| descendants(child, acc) if acc.add?(child) }
      acc
    end

    def model?(fqn)
      chain = [fqn] + ancestors(fqn)
      chain.include?("ApplicationRecord") || external_base(fqn) == "ActiveRecord::Base"
    end

    def controller?(fqn)
      ns = @namespaces[fqn]
      ns&.kind == :class && fqn.end_with?("Controller") &&
        ns.locations.any? { |l| l.path.include?("controllers/") }
    end

    def channel?(fqn)
      ([fqn] + ancestors(fqn)).include?("ApplicationCable::Channel") ||
        external_base(fqn).to_s.start_with?("ActionCable::Channel")
    end

    def library_namespace?(fqn)
      top = fqn.split("::").first
      @gem_namespaces.include?(DeadCode.normalize(top)) || DeadCode.core_constant?(top)
    end

    # ---------------------------------------------------------------- routes

    def map_routes
      @routed = Hash.new { |h, k| h[k] = Set.new }
      @routed_everything = Set.new
      @all_routed_actions = Set.new
      @unmatched_route_controllers = []
      return unless @routes

      @routes.actions.each do |controller_path, actions|
        fqn = controller_for(controller_path)
        if fqn
          @routed[fqn].merge(actions)
          @all_routed_actions.merge(actions)
        else
          @unmatched_route_controllers << controller_path
        end
      end
      @routes.wildcard_controllers.each { |path| (fqn = controller_for(path)) && (@routed_everything << fqn) }
      @routed_names_cache = {}
    end

    def controller_for(path) = @ns_by_norm_full[DeadCode.normalize("#{path.gsub("/", "::")}Controller")].first

    def routes_unknown? = @routes.nil? || @routes.dynamic

    # Routes to a subclass reach methods it inherits, so include descendants' routed actions.
    def routed_names(fqn)
      @routed_names_cache[fqn] ||= ([fqn] + descendants(fqn).to_a).each_with_object(Set.new) do |c, acc|
        acc.merge(@routed[c])
      end
    end

    def routable?(fqn)
      routes_unknown? || @routed_everything.include?(fqn) ||
        ([fqn] + descendants(fqn).to_a).any? { |c| @routed_everything.include?(c) }
    end

    def controller_action_candidate?(m)
      !m.singleton && m.public? && controller?(m.owner) && !hook?(m)
    end

    def routed?(m)
      return false if m.singleton || !m.public?

      if controller?(m.owner)
        routable?(m.owner) || routed_names(m.owner).include?(m.name)
      else
        # Public methods of controller concerns become actions of the controllers including them.
        @namespaces[m.owner]&.kind == :module &&
          m.locations.any? { |l| l.path.include?("controllers/") } &&
          (routes_unknown? || @all_routed_actions.include?(m.name))
      end
    end

    # ---------------------------------------------------------------- propagation

    def hook?(m) = @config.ignored_method?(m.name)

    def seed
      @live_ns = Set.new
      @live_methods = Set.new
      @live_scopes = Set.new
      @called = Set.new
      @called_scope_count = Hash.new(0)
      @queue = []

      live_scope!("root")
      live_scope!("config")
      live_ns!(MAIN)
      root_globs = @config["root_globs"]
      @namespaces.each_value do |ns|
        root = @config.ignored_constant?(ns.fqn) || library_namespace?(ns.fqn) ||
               ns.locations.any? do |l|
                 l.path.start_with?("app/helpers/") || # `helper :all` includes every helper module
                   root_globs.any? { |g| File.fnmatch?(g, l.path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
               end
        root ||= controller?(ns.fqn) && (routes_unknown? || @routed.key?(ns.fqn) || @routed_everything.include?(ns.fqn))
        live_ns!(ns.fqn) if root
      end
    end

    def propagate
      while (key = @queue.shift)
        refs = @index.scopes[key]
        next unless refs

        refs.names.each { |n| called!(n) }
        refs.symbols.each do |s|
          called!(s)
          called!("#{s}=")
          symbol_conventions(s)
        end
        refs.consts.each { |path, nesting| resolve_prefix(path, nesting).each { |fqn| live_ns!(fqn) } }
        refs.const_strings.each { |path| resolve_prefix(path, nil).each { |fqn| live_ns!(fqn) } }
        refs.normalized_consts.each { |norm| @ns_by_norm_last[norm].each { |fqn| live_ns!(fqn) } }
      end
    end

    def live_scope!(key)
      @queue << key if @live_scopes.add?(key)
    end

    def live_ns!(fqn)
      return unless fqn == MAIN || @namespaces.key?(fqn)
      return unless @live_ns.add?(fqn)

      live_scope!("C:#{fqn}")
      if fqn != MAIN
        parent = parent_ns(fqn)
        live_ns!(parent) if parent
        live_ns!("#{fqn}Policy") # Pundit infers FooPolicy from Foo
        live_ns!("#{fqn}::Scope") if fqn.end_with?("Policy") # ...and FooPolicy::Scope
      end
      @methods_by_owner[fqn].each do |m|
        live_method!(m) if hook?(m) || @called.include?(m.name) || routed?(m) || pundit_routed?(m)
      end
    end

    # `authorize record` in an action calls "#{action_name}?" on the record's policy.
    def pundit_routed?(m)
      m.owner.end_with?("Policy") && m.name.end_with?("?") && !m.singleton &&
        (routes_unknown? || @all_routed_actions.include?(m.name.delete_suffix("?")))
    end

    def called!(name)
      @called_scope_count[name] += 1
      return unless @called.add?(name)

      @methods_by_name[name].each { |m| live_method!(m) if @live_ns.include?(m.owner) }
    end

    def live_method!(m)
      live_scope!("M:#{m.key}") if @live_methods.add?(m.key)
    end

    def symbol_conventions(symbol)
      norm = DeadCode.normalize(symbol)
      CONVENTION_SYMBOL_SUFFIXES.each { |suffix| @ns_by_norm_last["#{norm}#{suffix}"].each { |fqn| live_ns!(fqn) } }
      @ns_by_norm_last[norm].each { |fqn| live_ns!(fqn) } if symbol.match?(CONVENTION_CLASS_SUFFIX_RE)
    end

    # ---------------------------------------------------------------- classification

    def classify
      prepare_classification
      findings = []
      dead = @namespaces.keys.reject { |fqn| @live_ns.include?(fqn) }.to_set
      dead.each do |fqn|
        parent = parent_ns(fqn)
        next if parent && dead.include?(parent) # rolled up into the parent's finding

        findings << namespace_finding(fqn, dead)
      end

      @index.methods.each_value do |m|
        next if m.owner != MAIN && !@live_ns.include?(m.owner)

        if controller_action_candidate?(m) && !routed?(m)
          findings << controller_action_finding(m)
        elsif !@live_methods.include?(m.key)
          findings << method_finding(m)
        end
      end
      findings
    end

    def prepare_classification
      live_refs = @live_scopes.filter_map { |k| @index.scopes[k] }
      @method_patterns = live_refs.flat_map { |r| r.method_patterns.to_a }.uniq.map { |p| Regexp.new(p) }
      @const_patterns = live_refs.flat_map { |r| r.const_patterns.to_a }.uniq.map { |p| Regexp.new(p) }
      @live_symbols = live_refs.each_with_object(Set.new) { |r, acc| acc.merge(r.symbols) }
      @descendant_roots = live_refs.flat_map do |r|
        r.descendant_roots.flat_map do |path, nesting|
          resolve(path, nesting)
        end
      end.to_set

      dead_refs = @index.scopes.except(*@live_scopes).values
      @names_in_dead_code = dead_refs.each_with_object(Set.new) { |r, acc| acc.merge(r.names).merge(r.symbols) }
      @consts_in_dead_code = dead_refs.each_with_object(Set.new) do |r, acc|
        r.consts.each { |path, nesting| acc.merge(resolve_prefix(path, nesting)) }
        r.const_strings.each { |path| acc.merge(resolve_prefix(path, nil)) }
      end

      # Implicit-receiver calls and symbols (before_action :x) per controller-side owner.
      @controller_side_names = Hash.new { |h, k| h[k] = Set.new }
      @concern_names = Set.new(@index.scopes["config"]&.symbols)
      @live_scopes.each do |key|
        owner = scope_owner(key)
        refs = @index.scopes[key]
        next unless owner && refs && controller_side?(owner)

        target = controller?(owner) ? @controller_side_names[owner] : @concern_names
        target.merge(refs.self_calls).merge(refs.symbols)
      end

      tests = @index.test_refs
      @test_names = tests.names | tests.symbols
      @test_consts = Set.new
      tests.consts.each { |pair| @test_consts << pair.first.delete_prefix("::").split("::").last }
      tests.const_strings.each { |path| @test_consts << path.split("::").last }
    end

    def namespace_finding(fqn, dead)
      family = [fqn] + dead.select { |d| d.start_with?("#{fqn}::") }
      reasons = family.flat_map { |f| namespace_doubts(f).map { |r| f == fqn ? r : "#{f}: #{r}" } }

      overlap = family.flat_map { |f| @methods_by_owner[f] }
                      .select { |m| m.public? && !hook?(m) && @called.include?(m.name) }
                      .map(&:name).uniq
                      .select { |n| @called_scope_count[n] <= @config["overlap_scope_threshold"] }
      if overlap.any?
        reasons << "never referenced, but method name(s) #{overlap.first(5).join(", ")} are called elsewhere " \
                   "(dynamic constant lookup or a name collision)"
      end

      ns = @namespaces[fqn]
      contained = family.sum { |f| @methods_by_owner[f].size }
      detail = [("#{family.size - 1} nested constant(s)" if family.size > 1),
                ("#{contained} method(s)" if contained.positive?)].compact
      base = "never referenced#{" (#{detail.join(", ")})" if detail.any?}"
      base += "; only referenced from other unused code" if family.any? { |f| @consts_in_dead_code.include?(f) }
      Finding.new(
        confidence: reasons.empty? ? :unused : :likely_unused,
        kind: ns.kind,
        name: fqn,
        location: ns.locations.first,
        reason: reasons.empty? ? base : reasons.first(3).join("; "),
        referenced_in_tests: family.any? { |f| @test_consts.include?(f.split("::").last) },
        definition_count: ns.locations.size,
        targets: family
      )
    end

    def namespace_doubts(fqn)
      doubts = []
      superclass = @superclass[fqn]
      abstract_parent = superclass == "ApplicationRecord" || @namespaces[superclass]&.flags&.include?(:abstract)
      if superclass && model?(fqn) && !abstract_parent
        doubts << "STI subclass of #{superclass} (may be instantiated from the type column)"
      end
      doubts << "ActionCable channel (subscribed to by name from JavaScript)" if channel?(fqn)
      if (root = ancestors(fqn).find { |a| @descendant_roots.include?(a) })
        doubts << "#{root}.descendants/subclasses is enumerated (eager-loaded subclasses are discovered)"
      end
      external = @external_superclass[fqn]
      if external && !@config["known_base_classes"].include?(external)
        doubts << "inherits from library class #{external} (it may discover or load subclasses itself)"
      end
      underscored = fqn.underscore
      if (pattern = @const_patterns.find do |p|
            p.match?(fqn) || p.match?(underscored) || p.match?(underscored.split("/").last)
          end)
        doubts << "matches dynamic constant lookup #{pattern.source}"
      end
      if (m = fqn.match(INFERRED_COMPANION_RE)) && @live_ns.include?(m[1])
        doubts << "#{m[2]} may be inferred from #{m[1]} by convention"
      end
      prefix = fqn.split("::").last.sub(/(?<=[a-z0-9])(?:Job|Worker|Mailer|Observer|Channel|Component|Input)\z/, "")
      if prefix != fqn.split("::").last && @live_symbols.include?(prefix.underscore)
        doubts << "a :#{prefix.underscore} symbol may refer to it by convention"
      end
      doubts
    end

    def scope_owner(key)
      return unless key.start_with?("C:", "M:")

      key[2..].split(/[#.](?=[^:]*\z)/).first
    end

    # Controllers and controller concerns: the only code that can call a controller's own methods
    # (views reach them only through `helper_method`, which is a symbol in the class body).
    def controller_side?(fqn)
      controller?(fqn) || (@namespaces[fqn]&.locations&.any? { |l| l.path.include?("controllers/") } || false)
    end

    def called_within_controller_hierarchy?(m)
      @concern_names.include?(m.name) ||
        ([m.owner] + ancestors(m.owner) + descendants(m.owner).to_a).any? do |c|
          @controller_side_names.key?(c) && @controller_side_names[c].include?(m.name)
        end
    end

    def controller_action_finding(m)
      filter_use = ([m.owner] + ancestors(m.owner)).any? { |c| @index.scopes["C:#{c}"]&.symbols&.include?(m.name) }
      external = external_base(m.owner)
      reason, confidence =
        if external && !@config["known_base_classes"].include?(external)
          ["no route; controller inherits from #{external}, which may route it", :likely_unused]
        elsif filter_use
          ["public, but no route; used as a filter/helper_method - consider making it private", :likely_unused]
        elsif called_within_controller_hierarchy?(m)
          ["public, but no route; called from controller code - consider making it private", :likely_unused]
        elsif @live_methods.include?(m.key)
          ["no route; only non-controller code calls a method with this name (likely a name collision)", :unused]
        else
          ["no route and never called", :unused]
        end
      build_method_finding(m, :controller_action, confidence, reason)
    end

    def method_finding(m)
      doubts = method_doubts(m)
      reason = "never called"
      reason += "; only called from other unused code" if @names_in_dead_code.include?(m.name)
      build_method_finding(m, :method, doubts.empty? ? :unused : :likely_unused,
                           doubts.empty? ? reason : doubts.join("; "))
    end

    def method_doubts(m)
      doubts = []
      if m.in_block && !METAPROGRAMMING_BLOCKS.include?(m.in_block)
        doubts << "defined inside a `#{m.in_block}` block (may be a DSL hook)"
      end
      if m.name.end_with?("=") && @namespaces[m.owner] && model?(m.owner)
        doubts << "model attribute writer (may be mass-assigned from request params)"
      end
      if (pattern = @method_patterns.find { |p| p.match?(m.name) })
        doubts << "matches dynamic dispatch #{pattern.source}"
      end
      if m.owner.end_with?("Policy") && m.name.end_with?("?")
        action = m.name.delete_suffix("?")
        doubts << "Pundit predicate; Pundit calls \"\#{action}?\" and no routed action is named #{action}"
      end
      doubts << "public method of an ActionCable channel (performed from JavaScript)" if m.public? && channel?(m.owner)
      if (external = external_base(m.owner)) && !@config["known_base_classes"].include?(external)
        doubts << "#{m.visibility} method on a subclass of #{external} (the library may call it)"
      end
      if m.owner != MAIN && library_namespace?(m.owner)
        doubts << "defined on library namespace #{m.owner} (the library may call it)"
      end
      if m.locations.all? { |l| l.path.start_with?("config/") } && !library_namespace?(m.owner)
        doubts << "defined in config/ (boot-time patch; a library may call it)"
      end
      doubts
    end

    # ---------------------------------------------------------------- removable tests

    def attach_tests(findings)
      index_test_blocks
      findings.each do |f|
        target = f.targets
        # A public controller method kept alive as a filter/helper is still in use: keep its tests.
        f.tests = if target.is_a?(MethodDef)
                    @live_methods.include?(target.key) ? [] : prune_nested(method_tests(target))
                  else
                    prune_nested(namespace_tests(target))
                  end
      end
    end

    def index_test_blocks
      @block_subjects = {}
      @groups_describing_const = Hash.new { |h, k| h[k] = [] }
      @examples_referencing_const = Hash.new { |h, k| h[k] = [] }
      @groups_describing_method = Hash.new { |h, k| h[k] = [] }
      @examples_calling = Hash.new { |h, k| h[k] = [] }
      resolved = Hash.new { |h, path| h[path] = resolve_prefix(path, []) }
      # A described constant must resolve exactly; falling back to its namespace would make
      # `RSpec.describe Billing::Unknown` look like a spec of `Billing`.
      subject_of = Hash.new { |h, path| h[path] = resolve(path, []) }

      walk = lambda do |block, inherited|
        own = block.const_path ? subject_of[block.const_path] : []
        subjects = own.any? ? own : inherited
        @block_subjects[block] = subjects
        if block.example?
          block.consts.each { |c| resolved[c].each { |fqn| @examples_referencing_const[fqn] << block } }
          block.names.each { |n| @examples_calling[n] << block }
        else
          own.each { |fqn| @groups_describing_const[fqn] << block }
          @groups_describing_method[block.method_name] << block if block.method_name
        end
        block.children.each { |child| walk.call(child, subjects) }
      end
      @index.test_blocks.each { |root| walk.call(root, []) }
    end

    def namespace_tests(family)
      family.flat_map do |fqn|
        @groups_describing_const[fqn].map { |b| [b, :describes] } +
          @examples_referencing_const[fqn].map { |b| [b, :calls] }
      end
    end

    # Only blocks whose subject (`RSpec.describe Post`, inherited by nested groups) is the method's
    # class or a subclass, so `describe "#publish"` in another class's spec isn't matched by name.
    def method_tests(m)
      return [] if m.owner == MAIN

      owners = Set[m.owner].merge(descendants(m.owner))
      about_owner = ->(b) { @block_subjects[b].any? { |fqn| owners.include?(fqn) } }
      scope_matches = ->(b) { b.method_scope.nil? || (b.method_scope == :singleton) == m.singleton }

      describing = @groups_describing_method[m.name].select { |b| about_owner.call(b) && scope_matches.call(b) }
      calling = @examples_calling[m.name].select { |b| about_owner.call(b) && !b.helper?(m.name) }
      describing.map { |b| [b, :describes] } + calling.map { |b| [b, :calls] }
    end

    # Drop blocks inside another selected block; a group outranks the examples it contains.
    def prune_nested(candidates)
      kept = []
      candidates.uniq { |b, _| b }.sort_by { |b, _| [b.path, b.first_line, -b.last_line] }.each do |block, match|
        next if kept.any? { |k, _| k.contains?(block) }

        kept << [block, match]
      end
      kept.map do |block, match|
        whole = block.whole_file # line count of the file when the block is all it holds
        TestRemoval.new(path: block.path, first_line: whole ? 1 : block.first_line,
                        last_line: whole || block.last_line, match:, whole_file: !!whole)
      end
    end

    def build_method_finding(m, kind, confidence, reason)
      Finding.new(confidence:, kind:, name: m.label, location: m.locations.first, reason:, targets: m,
                  referenced_in_tests: @test_names.include?(m.name), definition_count: m.locations.size)
    end
  end
end
