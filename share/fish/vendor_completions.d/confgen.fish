# Remove previous completions
complete -c confgen -e

complete -c confgen -s h -l help -d "Show help"
complete -c confgen -s c -l compile -d "Compile a template to Lua instead of running" -Fr
complete -c confgen -s j -l json-opt -d "Write the given or all fields from cg.opt to stdout as JSON after running the given confgenfile instead of running" -Fr
complete -c confgen -s f -l file -d "Evaluate a single template and write the output instead of running"
complete -c confgen -s e -l eval -r -d "Evaluate the given lua code before loading the confgenfile"
complete -c confgen -s p -l post-eval -r -d "Evaluate the given lua code after loading the confgenfile"
complete -c confgen -s w -l watch -r -d "Watch for changes of input files and re-generate them if changed"
