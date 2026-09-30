# todo

- Plain Ruby, no gems beyond minitest. Run `bin/test` before you finish; it must pass.
- Each command is one class in its own file under `lib/todo/commands/`, found automatically by name
  (`todo clear` -> `lib/todo/commands/clear.rb`, `Todo::Commands::Clear`), with its tests in
  `test/<command>_test.rb`. A new command needs no registration anywhere else.
- Keep changes small and in the style of the existing code. Leave the README alone.
