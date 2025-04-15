local Logging = require(game.ReplicatedStorage.Modules.Mega.Logging)

local LOG = Logging:new("Sentries.Utils")

local cloned = script.Parent.Cloned

local Utils = {}

function Utils.buildFromModel(model: Model, owner: Player?)
	local sentryScript = cloned.ServerSentry:Clone()
	model:SetAttribute("Owner", owner.UserId)
	sentryScript.Parent = model
	sentryScript.Enabled = true
end

return Utils
