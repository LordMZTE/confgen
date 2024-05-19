# Remove previous completions
complete -c confgenfs -e

complete -c confgenfs -s h -l help -d "Show help"
complete -c confgenfs -s e -l eval -r -d "Evaluate the given lua code before loading the confgenfile"
complete -c confgenfs -s p -l post-eval -r -d "Evaluate the given lua code after loading the confgenfile"
