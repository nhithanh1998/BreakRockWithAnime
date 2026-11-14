--!strict
-- LightingPresets: how the world is lit for each weather. Read by LightingController (client), which
-- tweens Lighting, Atmosphere, colour grading, Bloom, SunRays, DepthOfField and the Sky between them.
--
-- Rule of thumb for this game: soft, warm and readable (never glaring, never dark). Weather changes the mood (colour
-- temperature, a bit of haze, a bit of contrast) but never makes the map grey or dark.
--   * Atmosphere.Density stays <= ~0.42 so far things stay visible and near things stay crisp.
--   * Ambient / OutdoorAmbient stay high (shadows never go black), even at night.
--   * ExposureCompensation goes UP when the sky goes darker (rain / storm / night) to make up for it.
--   * Grade.Saturation stays around -0.1..0.1: muted, never neon, never washed out.
--   * Bloom Threshold stays > 1 by day: only neon / very bright things glow, nothing burns out.
--
-- Weathers pick a preset with Visual.Lighting in WeatherConfig (default: the weather's Id). No weather
-- = "Clear". ReplicatedStorage attribute "LightingPreset" (string) forces a preset (events / testing),
-- e.g. in the server command bar:  game.ReplicatedStorage:SetAttribute("LightingPreset", "Night")
--
-- A preset only needs the fields that differ from Clear; anything missing is taken from Clear.

export type Preset = {
	Lighting: { [string]: any }?, -- Brightness, Ambient, OutdoorAmbient, ColorShift_Top/Bottom, Environment*Scale, ExposureCompensation, ClockTime
	Atmosphere: { [string]: any }?, -- Density, Offset, Color, Decay, Glare, Haze
	Grade: { [string]: any }?, -- ColorCorrectionEffect: Brightness, Contrast, Saturation, TintColor
	Bloom: { [string]: any }?, -- Intensity, Size, Threshold
	SunRays: { [string]: any }?, -- Intensity, Spread
	DepthOfField: { [string]: any }?, -- FarIntensity, FocusDistance, InFocusRadius, NearIntensity (Enabled is handled for you)
	Sky: { [string]: any }?, -- StarCount, CelestialBodiesShown, SunAngularSize, MoonAngularSize; SkyboxBk/Dn/Ft/Lf/Rt/Up to swap textures
}

local rgb = Color3.fromRGB

local LightingPresets = {}

LightingPresets.TweenTime = 3 -- seconds for a weather change (2-4 feels smooth)

LightingPresets.Presets = {
	-- Sunny: a soft, warm autumn afternoon (easy on the eyes: lower sun, muted colours, warm haze, no
	-- glare). Everything else falls back to these values.
	Clear = {
		Lighting = {
			Brightness = 2.3,
			ClockTime = 14.5,
			Ambient = rgb(138, 132, 124),
			OutdoorAmbient = rgb(158, 152, 142),
			ColorShift_Top = rgb(255, 236, 212),
			ColorShift_Bottom = rgb(40, 40, 50),
			EnvironmentDiffuseScale = 0.9,
			EnvironmentSpecularScale = 0.2,
			ExposureCompensation = -0.05,
		},
		Atmosphere = { Density = 0.24, Offset = 0.12, Color = rgb(232, 222, 204), Decay = rgb(188, 172, 150), Glare = 0, Haze = 1 },
		Grade = { Brightness = 0, Contrast = 0.04, Saturation = -0.1, TintColor = rgb(255, 246, 232) },
		Bloom = { Intensity = 0.15, Size = 20, Threshold = 1.8 },
		SunRays = { Intensity = 0.03, Spread = 0.2 },
		DepthOfField = { FarIntensity = 0, NearIntensity = 0, FocusDistance = 50, InFocusRadius = 50 },
		Sky = { StarCount = 0, CelestialBodiesShown = true, SunAngularSize = 12, MoonAngularSize = 11 },
	},

	-- Overcast: soft, even light, mild colours, still clean.
	Cloudy = {
		Lighting = {
			Brightness = 2.8,
			Ambient = rgb(160, 160, 165),
			OutdoorAmbient = rgb(182, 184, 190),
			ColorShift_Top = rgb(228, 232, 242),
			ExposureCompensation = 0.2,
		},
		Atmosphere = { Density = 0.28, Offset = 0.12, Color = rgb(218, 224, 234), Decay = rgb(172, 182, 198), Glare = 0, Haze = 1.2 },
		Grade = { Brightness = 0.04, Contrast = 0.05, Saturation = 0.08, TintColor = rgb(250, 252, 255) },
		Bloom = { Intensity = 0.25 },
		SunRays = { Intensity = 0.02 },
		Sky = { SunAngularSize = 8 },
	},

	-- Rain: a little cool and blue, but bright with normal contrast.
	Rain = {
		Lighting = {
			Brightness = 2.6,
			ClockTime = 14,
			Ambient = rgb(150, 160, 180),
			OutdoorAmbient = rgb(172, 184, 202),
			ColorShift_Top = rgb(205, 218, 242),
			ExposureCompensation = 0.25,
		},
		Atmosphere = { Density = 0.3, Offset = 0.1, Color = rgb(196, 212, 232), Decay = rgb(150, 170, 200), Glare = 0, Haze = 1.5 },
		Grade = { Brightness = 0.05, Contrast = 0.06, Saturation = 0.04, TintColor = rgb(236, 244, 255) },
		Bloom = { Intensity = 0.25, Size = 24, Threshold = 1.3 },
		SunRays = { Intensity = 0 },
		Sky = { SunAngularSize = 0 },
	},

	-- Thunderstorm: the most dramatic one (slightly darker, cooler, more contrast), still fully readable.
	Storm = {
		Lighting = {
			Brightness = 2.2,
			ClockTime = 14,
			Ambient = rgb(138, 144, 170),
			OutdoorAmbient = rgb(152, 160, 188),
			ColorShift_Top = rgb(188, 198, 232),
			ExposureCompensation = 0.25,
		},
		Atmosphere = { Density = 0.34, Offset = 0.08, Color = rgb(172, 182, 208), Decay = rgb(122, 132, 168), Glare = 0, Haze = 2 },
		Grade = { Brightness = 0.04, Contrast = 0.1, Saturation = 0.02, TintColor = rgb(228, 234, 255) },
		Bloom = { Intensity = 0.3, Size = 24, Threshold = 1.25 },
		SunRays = { Intensity = 0 },
		Sky = { SunAngularSize = 0 },
	},

	-- Fog: milky white, far things fade but anything near stays sharp.
	Fog = {
		Lighting = {
			Brightness = 2.8,
			Ambient = rgb(175, 175, 182),
			OutdoorAmbient = rgb(196, 196, 202),
			ColorShift_Top = rgb(240, 240, 246),
			ExposureCompensation = 0.25,
		},
		Atmosphere = { Density = 0.42, Offset = 0, Color = rgb(236, 238, 243), Decay = rgb(224, 228, 236), Glare = 0, Haze = 2.5 },
		Grade = { Brightness = 0.06, Contrast = 0.03, Saturation = 0.06, TintColor = rgb(250, 251, 255) },
		Bloom = { Intensity = 0.2 },
		SunRays = { Intensity = 0 },
		Sky = { SunAngularSize = 0 },
	},

	-- Snow: crisp white, light icy blue, soft glow.
	Snow = {
		Lighting = {
			Brightness = 3,
			Ambient = rgb(175, 186, 206),
			OutdoorAmbient = rgb(196, 210, 232),
			ColorShift_Top = rgb(218, 232, 255),
			ExposureCompensation = 0.12,
		},
		Atmosphere = { Density = 0.3, Offset = 0.1, Color = rgb(226, 238, 255), Decay = rgb(190, 214, 245), Glare = 0.1, Haze = 1.2 },
		Grade = { Brightness = 0.05, Contrast = 0.06, Saturation = 0.06, TintColor = rgb(240, 248, 255) },
		Bloom = { Intensity = 0.4, Size = 26, Threshold = 1.15 },
		SunRays = { Intensity = 0.03, Spread = 0.2 },
	},

	-- Night: "blue moonlight" night. High ambient + exposure so nothing goes black.
	Night = {
		Lighting = {
			Brightness = 2,
			ClockTime = 0,
			Ambient = rgb(122, 136, 186),
			OutdoorAmbient = rgb(132, 152, 206),
			ColorShift_Top = rgb(160, 182, 255),
			ColorShift_Bottom = rgb(40, 50, 90),
			EnvironmentDiffuseScale = 0.6,
			ExposureCompensation = 0.6,
		},
		Atmosphere = { Density = 0.25, Offset = 0.2, Color = rgb(96, 116, 178), Decay = rgb(60, 82, 146), Glare = 0, Haze = 0.6 },
		Grade = { Brightness = 0.08, Contrast = 0.05, Saturation = 0.12, TintColor = rgb(218, 230, 255) },
		Bloom = { Intensity = 0.45, Size = 28, Threshold = 1 },
		SunRays = { Intensity = 0 },
		Sky = { StarCount = 3000, MoonAngularSize = 16 },
	},

	-- Game weathers ------------------------------------------------------------------------------------

	-- Sandstorm: warm amber haze, bright.
	Sandstorm = {
		Lighting = {
			Brightness = 2.9,
			Ambient = rgb(170, 155, 130),
			OutdoorAmbient = rgb(196, 178, 148),
			ColorShift_Top = rgb(255, 225, 180),
			ExposureCompensation = 0.2,
		},
		Atmosphere = { Density = 0.36, Offset = 0.05, Color = rgb(240, 212, 160), Decay = rgb(215, 175, 115), Glare = 0.2, Haze = 2 },
		Grade = { Brightness = 0.05, Contrast = 0.06, Saturation = 0.1, TintColor = rgb(255, 242, 222) },
		Bloom = { Intensity = 0.3 },
		SunRays = { Intensity = 0.04, Spread = 0.4 },
	},

	-- Golden Hour: rich warm late-afternoon light, extra glow.
	Golden = {
		Lighting = {
			Brightness = 3.3,
			ClockTime = 16.3,
			Ambient = rgb(170, 150, 125),
			OutdoorAmbient = rgb(196, 172, 140),
			ColorShift_Top = rgb(255, 215, 150),
			ExposureCompensation = 0.2,
		},
		Atmosphere = { Density = 0.22, Offset = 0.15, Color = rgb(255, 222, 180), Decay = rgb(240, 180, 120), Glare = 0.4, Haze = 0.8 },
		Grade = { Brightness = 0.05, Contrast = 0.08, Saturation = 0.25, TintColor = rgb(255, 240, 215) },
		Bloom = { Intensity = 0.45, Size = 26, Threshold = 1.15 },
		SunRays = { Intensity = 0.1, Spread = 0.35 },
	},

	-- Blood Moon: a night with a red / magenta tint, still bright enough to play.
	BloodMoon = {
		Lighting = {
			Brightness = 2,
			ClockTime = 0,
			Ambient = rgb(165, 120, 135),
			OutdoorAmbient = rgb(180, 130, 145),
			ColorShift_Top = rgb(255, 150, 150),
			ColorShift_Bottom = rgb(70, 30, 40),
			EnvironmentDiffuseScale = 0.6,
			ExposureCompensation = 0.55,
		},
		Atmosphere = { Density = 0.27, Offset = 0.15, Color = rgb(175, 80, 90), Decay = rgb(120, 30, 45), Glare = 0, Haze = 0.8 },
		Grade = { Brightness = 0.07, Contrast = 0.08, Saturation = 0.15, TintColor = rgb(255, 220, 222) },
		Bloom = { Intensity = 0.5, Size = 28, Threshold = 1 },
		SunRays = { Intensity = 0 },
		Sky = { StarCount = 1500, MoonAngularSize = 0 }, -- WeatherFX draws its own big red moon
	},

	-- Aurora: a teal / green magic night.
	Aurora = {
		Lighting = {
			Brightness = 2,
			ClockTime = 0,
			Ambient = rgb(118, 160, 170),
			OutdoorAmbient = rgb(128, 178, 190),
			ColorShift_Top = rgb(150, 255, 220),
			ColorShift_Bottom = rgb(40, 70, 90),
			EnvironmentDiffuseScale = 0.6,
			ExposureCompensation = 0.6,
		},
		Atmosphere = { Density = 0.24, Offset = 0.2, Color = rgb(90, 150, 165), Decay = rgb(50, 110, 140), Glare = 0, Haze = 0.6 },
		Grade = { Brightness = 0.08, Contrast = 0.05, Saturation = 0.22, TintColor = rgb(215, 255, 240) },
		Bloom = { Intensity = 0.55, Size = 30, Threshold = 0.95 },
		SunRays = { Intensity = 0 },
		Sky = { StarCount = 3000, MoonAngularSize = 14 },
	},

	-- Rainbow Storm: Clear turned up — the most colourful one.
	Rainbow = {
		Lighting = {
			Brightness = 3.3,
			ClockTime = 13,
			Ambient = rgb(165, 155, 170),
			OutdoorAmbient = rgb(185, 178, 192),
			ColorShift_Top = rgb(255, 235, 250),
		},
		Atmosphere = { Density = 0.2, Offset = 0.15, Color = rgb(235, 225, 255), Decay = rgb(200, 170, 240), Glare = 0.2, Haze = 0.5 },
		Grade = { Brightness = 0.05, Contrast = 0.1, Saturation = 0.35, TintColor = rgb(255, 245, 252) },
		Bloom = { Intensity = 0.45, Size = 26, Threshold = 1.15 },
		SunRays = { Intensity = 0.08, Spread = 0.3 },
	},
} :: { [string]: Preset }

-- Groups every preset has (in this order).
LightingPresets.Groups = { "Lighting", "Atmosphere", "Grade", "Bloom", "SunRays", "DepthOfField", "Sky" }

-- The preset `name` with every missing value filled in from Clear. Unknown names give Clear.
function LightingPresets.Resolve(name: string?): { [string]: { [string]: any } }
	local clear = LightingPresets.Presets.Clear :: any
	local preset = ((name and LightingPresets.Presets[name]) or clear) :: any
	local out = {}
	for _, group in LightingPresets.Groups do
		local merged = {}
		for k, v in clear[group] or {} do
			merged[k] = v
		end
		for k, v in preset[group] or {} do
			merged[k] = v
		end
		out[group] = merged
	end
	return out
end

return LightingPresets
