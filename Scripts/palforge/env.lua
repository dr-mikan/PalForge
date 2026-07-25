-- PalForge env: the shared, mutable runtime config. Cached by require(), so this
-- table is a process-wide singleton — any module reads `require("palforge.env").dev`
-- and main.lua (or a companion mod) may override a field by mutating this table
-- BEFORE calling registry.initialize().
--
--   local env = require("palforge.env")
--   if env.dev then ... end          -- read
--   env.dev = false                   -- release build (do this before initialize())
--
-- `dev` is THE single dev/release toggle: when true the kernel additionally loads
-- the dev keybinds and the test suites (see palforge.core.registry). Flip it to
-- false to ship a quiet release build with only the content catalogs registered.
return {
    dev     = true,        -- THE dev/release switch (dev tools load only when true)
    name    = "PalForge",
    version = "0.3.0",
}
