# confgen

confgen is a tool to generate config files using a custom template language.

The system is backed by a Lua runtime that is used to configure the tool.

## Usage

Start by creating `confgen.lua` in your dotfiles. It should look something like this:

```lua
-- add your config files
cg.addString("my_config.cfg", [[config template here]])
cg.addFile("my_other_config.cfg")
cg.addFile("my_other_config.cfg", "out.cfg") -- with output path
cg.addPath(".config") -- add a whole path recursively

-- set options to be used in config files
cg.opt.test_option = "42"
```

Next, add some templates. confgen will detect if a file is a template by its extension and copy it otherwise.
This is what a template looks like:

```cfg
I'm a confgen template!
<! if some_condition then !> # any lua statement
some option: <% opt.test_option %> # a lua expression
<! end !> # close the if block
more config stuff
```

Template files end with the `.cgt` extension. If a file that has been added has this extension, confgen will evaluate the template and put that into the output directory (without the `.cgt` extension), otherwise, it will be copied.

For example, if you want to add a file called `stuff.cfg` to the output as a template, you'd call the template file `stuff.cfg.cgt`.

With the above `confgen.lua`, this template

```
<! for i = 0,5 do !><% i %><! end !>

<% opt.test_option %>
```

would result in this output.

```
12345

42
```

Lastly, run confgen, providing the output directory as an argument:

```bash
confgen out_dir
```

## Building

### Linux

- install the luajit library and the master version of Zig
- `zig build -Drelease-fast -p ~/.local`

### Mac

This is untested, but it should work theoretically.

### Windows

no lol
