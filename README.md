# Dead code analyzer

Static report of code in a Rails 7 app that nothing outside of tests reaches: whole modules, classes, methods,
and controller actions without a route. Nothing is booted or eager-loaded. Code is parsed with
[Prism](https://github.com/ruby/prism) (Ruby's own parser) and routes are read by evaluating `config/routes.rb` statically.

```bash
BUNDLE_GEMFILE=script/dead_code/Gemfile bundle install   # once; own bundle, the app's Gemfile.lock is untouched
script/dead_code/analyze                                  # terminal report for the app in the current directory
script/dead_code/analyze --csv tmp/dead_code.csv          # also write a CSV
script/dead_code/analyze --path app/models --only unused  # narrow what is reported (analysis stays app-wide)
script/dead_code/analyze --ignore script/one_offs --ignore 'lib/tasks/**/backfill_*.rake'
```

`--ignore` (repeatable) takes a file, a directory, or a glob relative to the app root. Ignored files are left out
completely: their classes and methods aren't reported, and their calls don't keep other code alive. Ignoring one-off
scripts therefore surfaces code that only those scripts used. `db/migrate`, `vendor` and the other `exclude_globs`
in `lib/dead_code/config.rb` are always skipped. Put permanent ignores under `extra_exclude_globs` in
`.dead_code.yml`.

## How it decides

Entry points are live: top-level code (initializers, rake files, `script/`, seeds, views, YAML), routed controller
actions, helper modules, framework hooks (`perform`, `call`, `to_param`, callback method names, ...), and anything
reopened from a gem namespace (monkey patches). A live scope makes live whatever it references: method calls,
symbols (`before_save :x`, `&:x`, `permit(:x)`), constants, and identifier-like strings. This repeats until nothing
changes. Whatever was never reached is reported, so code only called by other dead code is reported as well.

- A class or module nobody references is one finding. Its methods and nested constants are not listed separately.
- References from `spec/` and `test/` never keep code alive. They show up as `referenced in tests`.
- Methods are matched by name, not by receiver type, so a common name (`name`, `call`) keeps every method with
  that name alive. The tool errs towards "used".

**UNUSED** means no static path reaches it. **LIKELY UNUSED** means no static reference exists, but a Rails or
Ruby convention could reach it at runtime. Each finding says which convention:

| Reason | Example |
| --- | --- |
| dynamic dispatch / constant lookup | `public_send("sort_by_#{field}")`, `Object.const_get("#{iso}AddressFormatter")` |
| STI subclass | `class Featured < Post`, which can be instantiated from the `type` column |
| `descendants` / `subclasses` enumerated | eager loading discovers the subclasses |
| subclass of a library class | Devise controllers, `Liquid::Drop`, `Rails::Railtie` |
| Pundit predicate with no matching action | `def frobnicate?` in a policy |
| DSL block, gem namespace, `config/` patch | `ActiveAdmin.register X do controller do def ...` |
| model attribute writer | `foo=` mass-assigned from request params |
| unrouted public controller method used as a filter | `before_action :foo` on a public method (make it private) |

## Removable tests

Each finding lists the test blocks that go away with it, indented under the finding:

```
    app/models/post.rb:8   Post#unused_method  - never called; referenced in tests
        spec/models/post_spec.rb:7-11
        spec/models/post_spec.rb:24 (example calls it)
    app/services/dead_service.rb:1   DeadService  - never referenced (2 method(s))
        spec/services/dead_service_spec.rb:1-5 (entire file)
```

`--csv out.csv` also writes `out_tests.csv`, with one row per block: test file, lines, match, entire file, and the
finding it belongs to.

- **describes**: an RSpec group about the finding, such as `RSpec.describe DeadService` or `describe "#unused_method"`
  inside `RSpec.describe Post`. Minitest `class DeadServiceTest` counts too. `#` matches instance methods, `.`/`::`
  matches class methods.
- **calls**: an example (`it`/`specify`/`test`) whose own body calls the method or references the constant. Methods
  only match inside specs whose subject is the method's class or a subclass. A call that hits a spec-local helper
  (`def x`, `let(:x)`, `subject(:x)`) doesn't match.
- Nested blocks are merged into the outermost one. A file holding nothing but the block (and `require`s) is reported
  as the whole file.
- No tests are listed for a public controller method that is still used as a filter or helper.

A "calls" example can also cover live code, so read it before deleting.

## Routes

The default parser covers `namespace`, `scope`, `controller`, `resources`/`resource` (only/except/controller/module/
concerns/member/collection/nesting), verb helpers (`to:`, `controller:`/`action:`, `"path" => "c#a"`, path shorthand),
`root`, `concern(s)`, `draw`, and `devise_for`/`use_doorkeeper` `controllers`. If the app boots, the route table is
exact:

```bash
bin/rails runner script/dead_code/dump_routes.rb > tmp/routes.json
script/dead_code/analyze --routes-json tmp/routes.json
```

## Tuning

Put overrides in `.dead_code.yml` at the app root, or pass `--config path`. Keys are listed in
`lib/dead_code/config.rb`. A plain key replaces the default list. An `extra_` key appends to it:

```yaml
extra_ignore_methods: [liquid_method_missing, "/\\Awebhook_/"]   # exact names or /regex/
extra_ignore_constants: [LegacyApi]
extra_reference_globs: [lib/generators/**/*.rb]
```

## Known blind spots

- `send(variable)` with a non-literal argument can call any method. Those calls are not modeled.
- Constants or method names that only exist in the database or in external configuration, such as polymorphic `*_type`
  values, Liquid templates stored in the DB, or job names in a remote scheduler.
- Engines mounted from gems, and routes added by gems beyond `devise_for` and `use_doorkeeper`. Use `--routes-json`
  if this matters.

## Tests

```bash
cd script/dead_code && for f in test/*_test.rb; do ruby -Itest "$f"; done
```
