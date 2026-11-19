local Logging = require(game.ReplicatedStorage.Modules.Mega.Logging)

local LOG = Logging:new("Sentries.Utils")

local cloned = script.Parent.Cloned

local Utils = {}
local botDeployments = {}
local contexts = setmetatable({}, { __mode = "k" })

function Utils.getSourceContext(model: Model)
	return contexts[model]
end

-- Registration starts before placement yields, so removal also cancels pending builds.
function Utils.registerDeployment(model: Model, context, destroy)
	contexts[model] = context
	if not context or not context.BotId then return end
	local entries = botDeployments[context.BotId]
	if not entries then
		entries = {}
		botDeployments[context.BotId] = entries
	end
	entries[model] = destroy
	model.Destroying:Once(function()
		entries[model] = nil
		contexts[model] = nil
		if not next(entries) and botDeployments[context.BotId] == entries then
			botDeployments[context.BotId] = nil
		end
	end)
end

function Utils.cleanupBot(botId)
	local entries = botDeployments[botId]
	if not entries then return end
	botDeployments[botId] = nil
	for _, destroy in entries do destroy() end
end

function Utils.buildFromModel(model: Model, owner: Player?, context)
	if context then contexts[model] = context end
	local ownerVal = model:FindFirstChild("Owner")
	if not ownerVal then
		ownerVal = Instance.new("ObjectValue")
		ownerVal.Name = "Owner"
		ownerVal.Parent = model
	end
	if owner then
		ownerVal.Value = owner
	end

	local sentryScript = cloned.ServerSentry:Clone()
	sentryScript.Parent = model
	sentryScript.Enabled = true
end

return Utils
