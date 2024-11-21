local CollectionService = game:GetService("CollectionService")

local scripts = game.ReplicatedStorage.Modules.Sentries.Cloned

for _, model: Model in CollectionService:GetTagged("sentry") do
	local clone = scripts.ServerSentry:Clone()
	clone.Parent = model
	clone.Enabled = true

	--for _, s in scripts:GetChildren() do
	--	local clone = s:Clone()

	--end
end
