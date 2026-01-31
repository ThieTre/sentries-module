local Logging = require(game.ReplicatedStorage.Modules.Mega.Logging)

local LOG = Logging:new("Sentries.Utils")

local cloned = script.Parent.Cloned

local Utils = {}

function Utils.buildFromModel(model: Model, owner: Player?)
	local sentryScript = cloned.ServerSentry:Clone()
	sentryScript.Parent = model
	sentryScript.Enabled = true
	if owner then
		local ownerVal = model:WaitForChild("Owner")
		ownerVal.Value = owner
	end
end

return Utils
