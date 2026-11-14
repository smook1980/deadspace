# Dead code analyzer

Static report of code in a Rails 7 app that nothing outside of tests reaches: whole modules, classes, methods,
and controller actions without a route. Nothing is booted or eager-loaded. Code is parsed with
[Prism](https://github.com/ruby/prism) (Ruby's own parser) and routes are read by evaluating `config/routes.rb` statically.

```bash
BUNDLE_GEMFILE=script/dead_code/Gemfile bundle install   # once; own bundle, the app's Gemfile.lock is untouched
script/dead_code/analyze                                  # terminal report for the app in the current directory
script/dead_code/analyze --csv tmp/dead_code.csv          # also write a CSV
script/dead_code/analyze --path app/models --only unused  # narrow what is reported (analysis stays app-wide)
```

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
