local InstModify = require(game.ReplicatedStorage.Modules.Mega.Instances.Modify)

local cloned = script.Parent.Cloned

local Utils = {}

function Utils.buildFromModel(model: Model, owner: Player?)
	local sentryScript = cloned.ServerSentry:Clone()

	if owner then
		local ownerVal = InstModify.findOrCreateChild(model, "Owner", "ObjectValue")
		ownerVal.Value = (owner.Parent and owner) or nil
	end

	sentryScript.Parent = model
	sentryScript.Enabled = true
end

return Utils
