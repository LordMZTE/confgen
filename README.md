# Confgen

Confgen is a tool to generate config files using a custom template language.

The system is backed by a Lua runtime that is used to configure the tool.

## Installation

You can find binaries built on a Debian box in the releases tab, or build yourself like any other
Zig project.

### Nix

This project includes a Nix flake you can depend on. Additionally, the Confgen derivation as well as
derivations of other projects of mine are automatically built and pushed to an attic cache at
`https://nix.mzte.de/mzte` on every commit.

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
confgen confgen.lua out_dir
```

## ConfgenFS

ConfgenFS provides an alternative to the `confgen` CLI tool. It takes a path to a confgen file
as well as a mountpoint:
```bash
# Mount config at ~/confgenfs
confgenfs /path/to/confgen.lua ~/confgenfs
```

This mounts a FUSE3 filesystem containing all the config files. The advantage of this is that
the templates will be generated when the file is opened and not ahead of time.

Additionally, the filesystem will contain "meta-files" inside `_cgfs/`, currently only `_cgfs/eval`
and `_cgfs/opts.json`.
You can write some Lua code to the former file, and it will be evaluated in the global Lua context.
This allows for dynamic configurations, here's a practical example:

`.config/waybar/config.cgt`:
```json
{
    "modules-left": [
        <! if opt.compositor == "river" then !>
        "river/tags", "river/window"
        <! elseif opt.compositor == "hyprland" then !>
        "hyprland/workspaces", "hyprland/window"
        <! end !>
    ]
}
```

Your hyprland and river configs could set the compositor option on startup:
```bash
# For river:
echo 'cg.opt.compositor = "river"' >~/confgenfs/_cgfs/eval

# For hyprland:
echo 'cg.opt.compositor = "hyprland"' >~/confgenfs/_cgfs/eval
```

And when waybar is started afterwards, it would work without manual configuration changes (assuming a symlink `~/confgenfs/.config/waybar -> ~/.config/waybar`).

After starting river, we can see the final config:
```bash
$ cat ~/confgenfs/.config/waybar/config
{
    "modules-left": [

        "river/tags", "river/window"

    ]
}
```

## Building

### Linux

- install the LuaJIT and FUSE3 library and the 0.12 version of Zig
- `zig build -Drelease-fast -p ~/.local`

### Mac

This is untested, but it should work theoretically.

### Windows

no lol
