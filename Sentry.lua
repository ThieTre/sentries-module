local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Modules = ReplicatedStorage.Modules

local Logging = require(Modules.Mega.Logging)
local LiveConfig = require(Modules.Mega.Data.LiveConfig)
local Table = require(Modules.Mega.DataStructures.Table)
local InstModify = require(Modules.Mega.Instances.Modify)
local InstSearch = require(Modules.Mega.Instances.Search)
local EffectsManager = require(Modules.Mega.Utils.EffectsManager)
local SpaceUtils = require(Modules.Mega.Utils.Space)
local PlayerUtils = require(Modules.Mega.Utils.Player)
local Damage = require(Modules.Damage.Damage)

local assets = RunService:IsServer() and ServerStorage.Assets.Sentries

local SETTINGS = require(ReplicatedStorage.Settings.Sentries)
local LOG = Logging:new("Sentries.Sentry")

-----------------------------------------------------------
--------------------- Sentry Object ------------------------
-----------------------------------------------------------
--[[

	Programmable object representing a sentry
	
]]

local Sentry = {}
Sentry.__index = Sentry
export type Sentry = typeof(setmetatable({}, Sentry))

function Sentry:new(model: Model, owner: Player?)
	-- Create a new sentry object
	self = setmetatable({}, { __index = Sentry })
	self.settings = require(model.Settings)
	self.model = model
	self.main = model.Main
	self.firePoint = self.main.Attachment
	self.config = LiveConfig:new(self.model)
	self.target = nil
	self.config.Enabled = false
	self.effectsManager = EffectsManager:new(model:GetDescendants())

	-- Initial model setup if needed
	self.scriptFolder = model:FindFirstChild("Scripting")
	if not self.scriptFolder then
		self:_SetupModel()
	else
		-- Senty model has already been setup
		self.targetVal = self.model.Target
		self.teamVal = self.model.Team
		self.prompt = self.main.ProximityPrompt
		self.targetVal.Value = nil
		self.ownerVal = self.model.Owner

		-- Ui
		self.healthUi = self.model.HealthBar
		self.repairUi = self.main.RepairUi

		-- Events
		self.gatlingEvent = self.scriptFolder.GatlingEvent

		-- Reset barrel weld
		local barrelWeldPos = self.model:GetAttribute("BarrelWeldPosition")
		if barrelWeldPos then
			self.model.Barrel.Weld.C0 = CFrame.new(barrelWeldPos)
		end
	end

	self:_SetupHealth()

	-- Ownership
	if not self.ownerVal.Value and owner then
		self:SetOwner(owner)
	end
	self:SetTeam(self.settings.Sentry.Team)

	-- Firing
	self.currentAmmo = self.settings.Sentry.Capacity

	-- Search params
	self.searchParams = RaycastParams.new()
	self.searchParams.FilterDescendantsInstances = { self.model }
	self.searchParams.FilterType = Enum.RaycastFilterType.Exclude

	self:Enable()
	return self
end

-- =============== General Setup ==============

function Sentry:_SetupModel()
	CollectionService:AddTag(self.model, "sentry")

	-- General
	self.scriptFolder = InstModify.create("Folder", self.model, { Name = "Scripting" })
	self.prompt = InstModify.create("ProximityPrompt", self.main)
	self.targetVal = InstModify.create("ObjectValue", self.model, { Name = "Target" })
	self.teamVal = InstModify.create("ObjectValue", self.model, { Name = "Team" })

	-- Get owner value object, may already have been created
	-- by a utility function
	self.ownerVal = InstModify.findOrCreateChild(
		self.model,
		"Owner",
		"ObjectValue",
		{ Name = "Owner" }
	)

	-- Ui
	local uiAssets = assets:FindFirstChild("Ui") or assets
	self.healthUi = uiAssets.HealthBar:Clone()
	self.repairUi = uiAssets.RepairUi:Clone()
	self.repairUi.Parent = self.main
	self.healthUi.Parent = self.model

	if SETTINGS.EnemyIcon then
		InstModify.clone(SETTINGS.EnemyIcon, self.model, {
			MaxDistance = self.settings.Sentry.Range * 1.5,
		})
	end

	-- Events
	self.orientEvent =
		InstModify.create("RemoteEvent", self.scriptFolder, { Name = "OrientEvent" })
	self.gatlingEvent =
		InstModify.create("RemoteEvent", self.scriptFolder, { Name = "GatlingEvent" })

	-- Save initial barrel weld position
	if self.model:FindFirstChild("Barrel") then
		self.model:SetAttribute(
			"BarrelWeldPosition",
			self.model.Barrel.Weld.C0.Position
		)
	end

	-- Client script
	local clientScript = script.Parent.Cloned.ClientSentry:Clone()
	clientScript.Parent = self.model
	clientScript.Enabled = true
end

function Sentry:_SetupHealth()
	local config = self.config

	local function onHealthChange(new, prev)
		-- Ratio
		local ratio = math.clamp(new / self.settings.Sentry.Health, 0, 1)
		if ratio < 1 then
			self.healthUi.Enabled = true
			self.healthUi.Red.Green.Size = UDim2.fromScale(ratio, 1)
		else
			self.healthUi.Enabled = false
		end
		if new <= 0 then
			self:Disable()
		end
	end

	-- Health change
	config.Health = self.settings.Sentry.Health
	config.MaxHealth = self.settings.Sentry.MaxHealth
	onHealthChange(config.Health)
	config:Watch("Health", onHealthChange)

	-- Auto repair
	if self.settings.Sentry.RepairFrequency then
		task.spawn(function()
			while true do
				if
					self.config.Enabled
					and config.Health < self.settings.Sentry.Health
				then
					config.Health += (self.settings.Sentry.Health * self.settings.Sentry.RegenRatio)
				end
				task.wait(self.settings.Sentry.RepairFrequency)
			end
		end)
	end
end

-- =============== State ==============

function Sentry:Enable()
	if self.config.Enabled then
		LOG:Debug("Sentry is already enabled!")
		return
	end
	self.config.Enabled = true

	self.model:AddTag("Damageable")

	task.spawn(function()
		while self.config.Enabled do
			task.spawn(function()
				self:Search()
			end)
			task.wait(math.clamp(self.settings.Sentry.SearchSpeed, 1, 100))
		end
	end)
	self:Idle()
end

function Sentry:Disable()
	if self.settings.Sentry.PromptRevive then
		self.prompt.Enabled = true
	end
	self.model:RemoveTag("Damageable")
	self.config.Enabled = false
	self:SetTarget(nil)
	local light = self.model.Light
	if self.config.Health <= 0 and self.settings.Sentry.ReviveTime then
		if self.settings.Sentry.ReviveTime then
			task.spawn(function()
				local downCount = 0
				while not self.config.Enabled do
					self.repairUi.Enabled = true
					light.SpotLight.Enabled = true
					task.wait(0.5)
					self.repairUi.Enabled = false
					light.SpotLight.Enabled = false
					task.wait(0.5)
					downCount += 1
					if
						downCount >= self.settings.Sentry.ReviveTime
						and not self.config.Enabled
					then
						self:Enable()
						self.config.Health = self.settings.Sentry.Health / 2
					end
				end
				light.SpotLight.Enabled = true
				self.repairUi.Enabled = false
			end)
		end
	end
end

function Sentry:Idle()
	self.effectsManager:RunAll("Idle")
	local lightPart = self.model.Light
	lightPart.BrickColor = BrickColor.new("Lime green")
	lightPart.SpotLight.Color = Color3.new(0, 1, 0)
end

function Sentry:SetTeam(team: Team?)
	self.teamVal.Value = team
end

function Sentry:SetOwner(player: Player?)
	self.ownerVal.Value = player
	if self.teamVal then
		self.teamVal.Value = player and player.Team or nil
	end
	self:SetTarget(nil)
end

-- =============== Firing ==============

function Sentry:StartFire()
	self.isFiring = true
	self.effectsManager:RunAll("StartFire")
	task.wait(self.settings.Sentry.StartFireDelay)
	local thisFireId = tick()
	self.lastFireId = thisFireId
	local currentTarget = self.target
	if self.settings.Sentry.Type == "Gatling" then
		-- Gatling sentry effects
		local currentRate = self.settings.Sentry.FireRate
			* self.settings.Sentry.FireAcceleration
		local gatling = self.model.Gatling
		-- Actual firing
		task.spawn(function()
			while
				self.target
				and currentTarget == self.target
				and self.lastFireId == thisFireId
			do
				self:Fire()
				if currentRate > self.settings.Sentry.FireRate then
					currentRate *= 0.7
				end
				task.wait(currentRate)
			end
		end)
		-- Gatling spin
		task.spawn(function()
			local lastSentRate = nil
			while self.target and currentTarget == self.target do
				if not self.target.Parent then
					break
				end
				if currentRate == lastSentRate then
					break
				end
				lastSentRate = currentRate
				self.gatlingEvent:FireAllClients(currentRate)
				task.wait(currentRate)
			end
			self.effectsManager:RunAll("GatlingStop")
			self.gatlingEvent:FireAllClients(nil)
		end)
		task.wait(1.3)
		if self.target == currentRate then
			self.effectsManager:RunAll("GatlingStart")
		end
	else
		-- Basic sentry effects
		task.spawn(function()
			while
				self.target
				and currentTarget == self.target
				and self.lastFireId == thisFireId
			do
				if not self.target.Parent then
					break
				end
				self:Fire()
				task.wait(self.settings.Sentry.FireRate)
			end
		end)
	end
end

function Sentry:StopFire()
	self.isFiring = false
end

function Sentry:Fire()
	-- Conditions
	local target: BasePart = self.target
	if not target then
		return
	end
	if self.currentAmmo < 1 then
		self:Reload()
		return
	end
	local startPos = self.firePoint.WorldCFrame.Position
	local result: RaycastResult =
		SpaceUtils.castLineRay(startPos, self.target.Position, self.searchParams)
	self.currentAmmo -= 1
	self:FireEffects()
	if result then
		local damageOptions = Table.DeepCopy(self.settings.Damage)
		damageOptions.Dealer = self.model
		damageOptions.Taker = result.Instance
		damageOptions.Distance = { Distance = result.Distance }
		damageOptions.Metadata = { IgnoreState = true } -- ! TODO: REDO
		Damage.damage(damageOptions)
		local takerConfig = damageOptions.TakerInfo.Config

		local isDead = takerConfig and takerConfig.Health <= 0
		local canDamage = not Table.Find(damageOptions.AppliedMultipliers, 0)

		if isDead or not canDamage then
			self:SetTarget(nil)
		elseif not damageOptions.TakerInfo.IsDamageable then
			-- Target is probably covered by an object
			self:Search()
		end
	end
end

function Sentry:Reload()
	self.effectsManager:RunAll("Reload")
	if self.effectsManager.Reload1 then
		self.effectsManager.Reload1.Ended:Connect(function()
			self.effectsManager:RunAll("ReloadEnd")
		end)
	end
	task.wait(self.settings.Sentry.RelaodTime)
	self.currentAmmo = self.settings.Sentry.Capacity
end

function Sentry:FireEffects()
	local main = self.main

	-- Effects

	local emitter = self.effectsManager.BulletEmitter
	if emitter then
		local speed = 3500
		local lifetime = (self.firePoint.WorldCFrame.Position - self.target.Position).Magnitude
			/ speed
		emitter.Acceleration = Vector3.new()
		emitter.Speed = NumberRange.new(speed, speed)
		emitter.Lifetime = NumberRange.new(lifetime, lifetime)
		emitter:Emit(1)
	end

	self.effectsManager:RunAll("Fire")

	-- Barrel
	local barrel = self.model:FindFirstChild("Barrel")
	if barrel and self.settings.Sentry.OffsetBarrelStuds > 0 then
		task.spawn(function()
			local tweenInfo =
				TweenInfo.new(self.settings.Sentry.FireRate / 4, Enum.EasingStyle.Cubic)
			local offset = Vector3.new(self.settings.Sentry.OffsetBarrelStuds, 0, 0)
			if self.settings.Sentry.ZOffset then
				offset = Vector3.new(0, 0, self.settings.Sentry.OffsetBarrelStuds)
			end
			local tween1 = TweenService:Create(
				barrel.Weld,
				tweenInfo,
				{ C0 = barrel.Weld.C0 - offset }
			)
			local tween2 =
				TweenService:Create(barrel.Weld, tweenInfo, { C0 = barrel.Weld.C0 })
			tween1:Play()
			tween1.Completed:Wait()
			tween2:Play()
		end)
	end
end

-- =============== Target Finding ==============

function Sentry:Search()
	-- Look for a target
	if self.target then
		-- Keep tracking current target
		if self:CanSee(self.target) then
			return
		else
			self:SetTarget(nil)
		end
	end
	-- Look for new target
	local hrps = self:GetNearbyEnemyRoots(self.settings.Sentry.Range)
	for _, hrp in pairs(hrps) do
		if self:CanSee(hrp) then
			self:SetTarget(hrp)
			break
		end
	end
end

function Sentry:GetNearbyEnemyRoots(range)
	-- Function to efficiently find the number
	-- of nearby enemy root parts
	local team: Team = self.teamVal.Value
	local owner = self.ownerVal.Value
	local nearby = {}
	local players = (
		Table.Difference(Players:GetPlayers(), team and team:GetPlayers() or {})
	)
	for _, player: Player in players do
		local humanoid: Humanoid = PlayerUtils.getObjects(player, "Humanoid")
		if not humanoid or not humanoid.RootPart then
			continue
		end
		if not self:IsInRange(humanoid.RootPart.Position) then
			continue
		end

		local takerObject = player
		if humanoid.SeatPart then
			takerObject =
				InstSearch.findFirstAncestorTagged(humanoid.SeatPart, "Vehicle")
		end

		local damageOptions = Table.DeepCopy(self.settings.Damage)
		damageOptions.Dealer = owner
		damageOptions.Taker = takerObject
		damageOptions.Metadata = { IgnoreState = true }
		local canDamage = Damage.canDamage(damageOptions)
		if not canDamage then
			continue
		end

		-- Set as nearby
		if humanoid.Health > 0 then
			table.insert(nearby, player.Character:FindFirstChild("HumanoidRootPart"))
		end
	end
	return nearby
end

function Sentry:CanSee(targetPart: BasePart): boolean
	local startPos = self.firePoint.WorldCFrame.Position
	local result = (
		SpaceUtils.castLineRay(startPos, targetPart.Position, self.searchParams)
	)
	local instance = result and result.Instance
	if not instance then
		return false
	end
	if not self:IsInRange(targetPart.Position) then
		return false
	end
	local isDamageable = CollectionService:HasTag(
		instance:FindFirstAncestorWhichIsA("Model"),
		"Damageable"
	)
	if isDamageable or instance:IsDescendantOf(targetPart.Parent) then
		return true
	end
end

function Sentry:IsInRange(position: Vector3)
	local distance = (position - self.main.Position).Magnitude
	local min, max =
		(self.settings.Sentry.MinTargetDistance or 0), self.settings.Sentry.Range
	return distance >= min and distance <= max
end

function Sentry:SetTarget(hrp)
	self.target = hrp
	self.targetVal.Value = hrp
	if hrp and self.config.Enabled then
		local main = self.main
		local light = self.model.Light
		light.BrickColor = BrickColor.new("Really red")
		light.SpotLight.Color = Color3.new(1, 0, 0)
		self.effectsManager:Run("LockOn")
		if self.target and not self.isFiring then
			self:StartFire()
		end
	else
		self:StopFire()
		task.spawn(function()
			self:Idle()
		end)
	end
end

-- =============== Private ==============

--[[
	
	Persistent streaming only (???)

	Sentry movement will involved fast and repreated 
	event firing to clients.
	
]]

function Sentry.clientSetup(model: Model)
	-- TODO: this should all really be a client class...

	local main = model:WaitForChild("Main")
	local config = LiveConfig:new(model)
	local targetVal = InstSearch.quietWaitForChild(model, "Target")
	local teamVal = InstSearch.quietWaitForChild(model, "Team")
	local sentrySettings = require(model:WaitForChild("Settings")).Sentry
	local sentryScript = main.Parent:FindFirstChildWhichIsA("Script")
	local LocalPlayer = game.Players.LocalPlayer

	local effectsManager = EffectsManager:new(model:GetDescendants())

	local function evaluateIcon()
		local enemyIcon = model:FindFirstChild("EnemyIcon")
		if not enemyIcon then
			return
		end

		enemyIcon.Enabled = teamVal.Value ~= LocalPlayer.Team and config.Enabled
	end

	local activeTween
	local function orient(cframe, speed, force: boolean)
		if not force then
			local distance = LocalPlayer:DistanceFromCharacter(main.Position)
			if distance > (SETTINGS.MaxClientWanderDistance or 2100) then
				return
			end
		end

		if activeTween then
			activeTween:Cancel()
		end
		local tweenInfo = TweenInfo.new(speed, Enum.EasingStyle.Back)
		activeTween = TweenService:Create(main, tweenInfo, { CFrame = cframe })
		activeTween:Play()
	end

	local function target(currentTarget)
		local isLocalPlayerTarget = false

		if currentTarget then
			local character = LocalPlayer.Character
			if character then
				isLocalPlayerTarget = currentTarget:IsDescendantOf(character)
			end
		end

		task.spawn(function()
			while targetVal.Value == currentTarget and config.Enabled do
				local cframe = CFrame.new(main.CFrame.Position, currentTarget.Position)
				orient(cframe, sentrySettings.LockOnSpeed, isLocalPlayerTarget)
				task.wait(0.25)
			end
		end)
	end

	local function wander()
		task.delay(3, function()
			while not targetVal.Value and config.Enabled do
				effectsManager:RunAll("Wander")
				local randPos = Vector3.new(
					math.random(-1000, 1000),
					math.random(sentrySettings.WanderYMin, sentrySettings.WanderYMax),
					math.random(-1000, 1000)
				)
				local cframe = CFrame.new(main.CFrame.Position, randPos)
				orient(cframe, sentrySettings.WanderSpeed)

				task.wait(math.random( -- TODO: WANDER FREQUENCY SHOULD BE REDUCED
					sentrySettings.WanderFrequency * 3,
					sentrySettings.WanderFrequency * 4
				))
			end
		end)
	end

	local function enable()
		effectsManager:RunAll("Enable")
		wander()
	end

	local function disable()
		if config.Health <= 0 then
			effectsManager:RunAll("Disable")
			local pos = Vector3.new(
				math.random(-100, 100),
				main.Parent:GetPivot().Y - 3000,
				math.random(-100, 100)
			)
			orient(CFrame.new(main.CFrame.Position, pos), 2)
		end
	end

	local function onTargetChange()
		local currentTarget: BasePart = targetVal.Value
		if currentTarget then
			target(currentTarget)
		else
			wander()
		end
	end

	targetVal:GetPropertyChangedSignal("Value"):Connect(onTargetChange)

	config:Watch("Enabled", function(enabled)
		if enabled then
			enable()
		else
			disable()
		end
		evaluateIcon()
	end)

	config:Watch("Health", function(new, prev)
		local change = new - (prev or 0)
		if change > 0 then
			local gearSound = effectsManager.Gears
			local repairSounds = effectsManager.groups["RepairChoices"]
			if repairSounds then
				effectsManager:Run(repairSounds:RandomChoice())
			end
			effectsManager:RunAll("Repair")
		end
	end)

	if sentrySettings.Type == "Gatling" then
		local event = main.Parent.Scripting:WaitForChild("GatlingEvent")
		local gatling = model:WaitForChild("Gatling")
		local currentRate = nil
		event.OnClientEvent:Connect(function(newRate)
			currentRate = newRate
		end)
		task.spawn(function()
			while true do
				if not currentRate then
					task.wait(0.5)
					continue
				end
				local newCFrame = gatling.Weld.C1
					* CFrame.Angles(
						math.rad(400 / sentrySettings.FireAcceleration),
						0,
						0
					)
				local tweenInfo =
					TweenInfo.new(currentRate / 1.5, Enum.EasingStyle.Linear)
				local tween =
					TweenService:Create(gatling.Weld, tweenInfo, { C1 = newCFrame })
				tween:Play()
				task.wait(0.1)
			end
		end)
	end

	evaluateIcon()
	onTargetChange()

	teamVal:GetPropertyChangedSignal("Value"):Connect(evaluateIcon)
end

return Sentry
