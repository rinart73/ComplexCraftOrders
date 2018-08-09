local config = {}

config.author = "Rinart73"
config.name = "Complex Craft Orders"
config.homepage = ""
config.version = {
    major = 0, minor = 1, patch = 1, -- 0.17.1/0.18.0beta+
}
config.version.string = config.version.major..'.'..config.version.minor..'.'..config.version.patch


-- 0 - Disable
-- 1 - Errors
-- 2 - Warnings
-- 3 - Info (will show how much time takes server update)
-- 4 - Debug
config.logLevel = 2

config.modules = {
  "basic",
  -- place your module folder into "mods/ComplexCraftOrders/modules" and add your module name in this table
}

-- check conditions every X seconds
config.updateInterval = 10
-- max amount of rows that players can use. Client value only affects UI generation
config.maxRows = 50


return config