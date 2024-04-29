# Remove previous completions
complete -c confgen -e

complete -c confgen -s h -l help -d "Show help"
complete -c confgen -s c -l compile -d "Compile a template to Lua instead of running" -Fr
complete -c confgen -s j -l json-opt -d "Write the given or all fields from cg.opt to stdout as JSON after running the given confgenfile instead of running" -Fr
complete -c confgen -s f -l file -d "Evaluate a single template and write the output instead of running"
