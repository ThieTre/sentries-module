local Players = game:GetService("Players")
local Sentry = require(game.ReplicatedStorage.Modules.Sentries.Sentry)

local model = script.Parent
local uid = model:GetAttribute("Owner")
local owner = Players:GetPlayerByUserId(uid or -1)

Sentry:new(model, owner)
