local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Modules = ReplicatedStorage.Modules

local Logging = require(Modules.Mega.Logging)
local Replication = require(Modules.Mega.Replication)
local MiscUtils = require(Modules.Mega.Utils.Misc)
local PlayerUtils = require(Modules.Mega.Utils.Player)
local LiveConfig = require(Modules.Mega.Data.LiveConfig)
local Table = require(Modules.Mega.DataStructures.Table)
local InstModify = require(Modules.Mega.Instances.Modify)
local InstSearch = require(Modules.Mega.Instances.Search)
local SpaceUtils = require(Modules.Mega.Utils.Space)
local Damage = require(Modules.Damage.Damage)

local LOG = Logging:new("Sentries")

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
	local self = setmetatable({}, { __index = Sentry })
	self.settings = require(model.Settings)
	self.model = model
	self.main = model.Main
	self.firePoint = self.main.Attachment
	self.config = LiveConfig:new(self.model)
	self.target = nil
	self.config.Enabled = false

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
	self:SetOwner(owner)
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
	CollectionService:AddTag(self.model, "Damageable")
	CollectionService:AddTag(self.model, "Sentry")

	-- General
	self.scriptFolder =
		InstModify.create("Folder", self.model, { Name = "Scripting" })
	self.prompt = InstModify.create("ProximityPrompt", self.main)
	self.targetVal =
		InstModify.create("ObjectValue", self.model, { Name = "Target" })
	self.teamVal =
		InstModify.create("ObjectValue", self.model, { Name = "Team" })
	self.ownerVal =
		InstModify.create("ObjectValue", self.model, { Name = "Owner" })

	-- Ui
	self.healthUi = game.ServerStorage.Assets.Sentries.HealthBar:Clone()
	self.repairUi = game.ServerStorage.Assets.Sentries.RepairUi:Clone()
	self.repairUi.Parent = self.main
	self.healthUi.Parent = self.model

	-- Effects
	local effects = Table:new(ServerStorage.Assets.Sentries:GetChildren())
		:Filter(function(v)
			return v:IsA("ParticleEmitter") or v:IsA("Sound")
		end)
	InstModify.cloneMany(effects, self.main)

	-- Events
	self.orientEvent = InstModify.create(
		"RemoteEvent",
		self.scriptFolder,
		{ Name = "OrientEvent" }
	)
	self.gatlingEvent = InstModify.create(
		"RemoteEvent",
		self.scriptFolder,
		{ Name = "GatlingEvent" }
	)

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
	self.config.Enabled = false
	self:SetTarget(nil)
	local light = self.model.Light
	if self.settings.Sentry.ReviveTime then
		spawn(function()
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

function Sentry:Idle()
	local light = self.model.Light
	local main = self.main
	light.BrickColor = BrickColor.new("Lime green")
	light.SpotLight.Color = Color3.new(0, 1, 0)
	main.Loss:Play()
	main.Warning:Stop()
	main.StopFire:Play()
end

function Sentry:SetTeam(team: Team?)
	self.teamVal.Value = team
end

function Sentry:SetOwner(player: Player?)
	self.ownerVal.Value = player
	self:SetTarget(nil)
end

-- =============== Firing ==============

function Sentry:StartFire()
	self.isFiring = true
	self.main.InitiateFire:Play()
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
			self.main.Spin:Stop()
			self.gatlingEvent:FireAllClients(nil)
		end)
		task.wait(1.3)
		if self.target == currentRate then
			self.main.Spin:Play()
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
	local result: RaycastResult = SpaceUtils.castLineRay(
		startPos,
		self.target.Position,
		self.searchParams
	)
	self.currentAmmo -= 1
	self:FireEffects()
	if result then
		local damageOptions = Table.DeepCopy(self.settings.Damage)
		damageOptions.Dealer = self.ownerVal.Value
		damageOptions.Taker = result.Instance
		damageOptions.Distance = { Distance = result.Distance }
		damageOptions.Metadata = { IgnoreState = true } -- ! TODO: REDO
		Damage.damage(damageOptions)
		local takerConfig = damageOptions.TakerInfo.Config
		if takerConfig and takerConfig.Health <= 0 then
			self:SetTarget(nil)
		elseif not damageOptions.TakerInfo.IsDamageable then
			-- Target is probably covered by an object
			self:Search()
		end
	end
end

function Sentry:Reload()
	task.spawn(function()
		self.main.Reload1:Play()
		self.main.Reload1.Ended:Wait()
		self.main.Reload2:Play()
	end)
	task.wait(self.settings.Sentry.RelaodTime)
	self.currentAmmo = self.settings.Sentry.Capacity
end

function Sentry:FireEffects()
	local main = self.main

	-- Bullet
	local emitter = self.firePoint.Bullet
	local speed = 3500 / 3
	local lifetime = (
		self.firePoint.WorldCFrame.Position - self.target.Position
	).Magnitude / speed
	emitter.Speed = NumberRange.new(speed, speed)
	emitter.Lifetime = NumberRange.new(lifetime, lifetime)
	emitter:Emit(1)

	-- Sound
	local sound = main.Fire:Clone()
	sound.Parent = main
	sound.PlayOnRemove = true
	sound:Destroy()

	-- Lighting and effects
	local flash = self.firePoint.PointLight
	spawn(function()
		flash.Enabled = true
		task.wait(0.05)
		flash.Enabled = false
	end)
	main.Attachment.Flash:Emit(1)
	main.Attachment.Muzzle:Emit(3)
	main.Attachment.Spark:Emit(3)
	if main:FindFirstChild("Shell") then
		main.Shell.Shell:Emit(1)
	end

	-- Barrel
	local barrel = self.model:FindFirstChild("Barrel")
	if self.settings.Sentry.OffsetBarrelStuds > 0 and barrel then
		spawn(function()
			local tweenInfo = TweenInfo.new(
				self.settings.Sentry.FireRate / 4,
				Enum.EasingStyle.Cubic
			)
			local offset =
				Vector3.new(self.settings.Sentry.OffsetBarrelStuds, 0, 0)
			if self.settings.Sentry.ZOffset then
				offset =
					Vector3.new(0, 0, self.settings.Sentry.OffsetBarrelStuds)
			end
			local tween1 = TweenService:Create(
				barrel.Weld,
				tweenInfo,
				{ C0 = barrel.Weld.C0 - offset }
			)
			local tween2 = TweenService:Create(
				barrel.Weld,
				tweenInfo,
				{ C0 = barrel.Weld.C0 }
			)
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
	local players = Table.Difference(
		Players:GetPlayers(),
		team and team:GetPlayers() or {}
	)
	for _, player: Player in players do
		local distance = player:DistanceFromCharacter(self.main.Position)
		if distance <= 0 or distance > range then
			continue
		end
		if
			owner
			and not Damage.canDamage({
				Dealer = owner,
				Taker = player,
				Metadata = { IgnoreState = true }, -- ! TODO: FIX
			})
		then
			continue
		end

		-- Set as nearby
		local character = player.Character
		local hrp = character.HumanoidRootPart
		local humanoid = character.Humanoid
		if humanoid.Health > 0 then
			table.insert(
				nearby,
				player.Character:FindFirstChild("HumanoidRootPart")
			)
		end
	end
	return nearby
end

function Sentry:CanSee(hrp): boolean
	local startPos = self.firePoint.WorldCFrame.Position
	local result = SpaceUtils.castLineRay(
		startPos,
		hrp.Position,
		self.searchParams
	) or {}
	local instance = result.Instance
	if not instance or not instance.CanCollide then
		return false
	end
	local isDamageable = CollectionService:HasTag(
		instance:FindFirstAncestorWhichIsA("Model"),
		"Damageable"
	)
	if isDamageable or instance:IsDescendantOf(hrp.Parent) then
		return true
	end
end

function Sentry:SetTarget(hrp)
	self.target = hrp
	self.targetVal.Value = hrp
	if hrp and self.config.Enabled then
		local main = self.main
		local light = self.model.Light
		light.BrickColor = BrickColor.new("Really red")
		light.SpotLight.Color = Color3.new(1, 0, 0)
		main.Enemy:Play()
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

-- Persistent Streaming
--[[
	
	Persistent streaming only

	Sentry movement will involved fast and repreated 
	event firing to clients. To reduce receiving packets,
	this is done with the creation of new remote events
	to avoid having to send instances as a paremeter when
	using a Kernel force client wrapper.
	
]]

function Sentry.clientSetup(model: Model)
	-- TODO: this should all really be a client class...

	local main = model:WaitForChild("Main")
	local config = LiveConfig:new(model)
	local targetVal = InstSearch.quietWaitForChild(model, "Target")
	local sentrySettings = require(model:WaitForChild("Settings")).Sentry
	local sentryScript = main.Parent:FindFirstChildWhichIsA("Script")

	local function orient(cframe: CFrame, speed: number)
		local tweenInfo = TweenInfo.new(speed, Enum.EasingStyle.Back)
		local tween = TweenService:Create(main, tweenInfo, { CFrame = cframe })
		tween:Play()
	end

	local function target(currentTarget)
		task.spawn(function()
			while targetVal.Value == currentTarget and config.Enabled do
				local cframe =
					CFrame.new(main.CFrame.Position, currentTarget.Position)
				orient(cframe, sentrySettings.LockOnSpeed)
				task.wait(0.1)
			end
		end)
	end

	local function wander()
		task.delay(3, function()
			while not targetVal.Value and config.Enabled do
				main.Servo.PlaybackSpeed = math.random(90, 110) / 100
				main.Servo:Play()
				local randPos = Vector3.new(
					math.random(-1000, 1000),
					math.random(
						sentrySettings.WanderYMin,
						sentrySettings.WanderYMax
					),
					math.random(-1000, 1000)
				)
				local cframe = CFrame.new(main.CFrame.Position, randPos)
				orient(cframe, sentrySettings.WanderSpeed)
				task.wait(math.random(2, sentrySettings.WanderFrequency))
			end
		end)
	end

	local function enable()
		main.Smoke.Enabled = false
		main.Down:Stop()
		wander()
	end

	local function disable()
		local light = model.Light
		main.Explode:Emit(15)
		main.Smoke.Enabled = true
		main.Disable:Play()
		main.Shutdown:Play()
		main.Down:Play()
		local pos = Vector3.new(
			math.random(-1000, 1000),
			main.Parent:GetPivot().Y - 1000,
			math.random(-1000, 1000)
		)
		orient(
			CFrame.new(main.CFrame.Position, pos),
			sentrySettings.WanderSpeed
		)
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
	end)

	config:Watch("Health", function(new, prev)
		local change = new - (prev or 0)
		if change > 0 then
			local gearSound = main.Gears
			local repairSounds = { main.Drill, main.Hammer, main.Pump }
			local randSound = Table.RandomChoice(repairSounds)
			gearSound:Play()
			randSound:Play()
			main.HealthSmoke:Emit(4)
			main.Parts:Emit(4)
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
				local tween = TweenService:Create(
					gatling.Weld,
					tweenInfo,
					{ C1 = newCFrame }
				)
				tween:Play()
				task.wait(0.1)
			end
		end)
	end

	onTargetChange()
end

return Sentry
