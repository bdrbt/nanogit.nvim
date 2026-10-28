# Nano Git

WIP: A simple reactive Git library for use with Neovim plugins.

Usage:

``` lua
local nanogit = require("nanogit")

local unsubscribe = nanogit.on_update(function(state)
    print("root:", state.root)
    print("branch:", state.branch)
    print("detached:", state.detached)
    vim.print(state.statuses)
end)

nanogit.setup()

-- Later, if needed:

unsubscribe()
nanogit.stop()
```
