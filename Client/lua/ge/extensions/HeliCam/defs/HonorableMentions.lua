local function rgbToColorF(r, g, b, a) return ColorF(r / 255, g / 255, b / 255, (a or 127) / 127) end
return {
	_default = {
		textcolor = rgbToColorF(255, 255, 255),
		background = ColorI(0, 0, 0, 127),
		orb = rgbToColorF(122, 122, 122, 64),
		postfix = nil
	},
	--_test = {
	--	textcolor = rgbToColorF(255, 208, 0),
	--	background = ColorI(0, 0, 0, 127),
	--	orb = rgbToColorF(255, 140, 0, 64),
	--	postfix = nil
	--},
	Neverless = {
		textcolor = rgbToColorF(255, 215, 0),
		background = ColorI(0, 0, 0, 127),
		orb = rgbToColorF(255, 140, 0, 64),
		postfix = ' [Author]'
	},
	jessbob = {
		textcolor = rgbToColorF(255, 255, 255),
		background = ColorI(62, 0, 130, 127),
		orb = rgbToColorF(255, 228, 181, 64),
		postfix = ' [NoobBob]'
	},
	LiterallyAPastry = { -- CaRP
		textcolor = rgbToColorF(255, 255, 255),
		background = ColorI(255, 130, 0, 127),
		orb = rgbToColorF(255, 130, 0, 64),
		postfix = ' [HeliPstry]'
	},
	["2PXL"] = { -- CaRP
		textcolor = rgbToColorF(255, 255, 255),
		background = ColorI(255, 20, 148, 127),
		orb = rgbToColorF(255, 20, 148, 64),
		postfix = ' [Choppa]'
	},
	Jaydeninja = { -- BeamMP
		textcolor = rgbToColorF(255, 199, 0),
		background = ColorI(156, 4, 4, 127),
		orb = rgbToColorF(255, 199, 0, 64),
		postfix = ' [Ferrari Strategist]'
	},
	SeaRaider = { -- CaRP
		textcolor = rgbToColorF(255, 215, 0),
		background = ColorI(158, 32, 57, 127),
		orb = rgbToColorF(158, 32, 57, 64),
		postfix = ' [helicopter helicopter]'
	},
	Hellrockets = { -- CaRP
		textcolor = rgbToColorF(255, 255, 0),
		background = ColorI(0, 0, 0, 127),
		orb = rgbToColorF(0,0,0, 64),
		postfix = ' [Lil Guy]'
	},
	gabstar = {
		textcolor = rgbToColorF(255, 255, 255),
		background = ColorI(98, 168, 165, 127),
		orb = rgbToColorF(61, 166, 162, 64),
		postfix = ' [Nodelet]'
	},
	Please_Pick_a_Name = { -- CaRP
		textcolor = rgbToColorF(0, 127, 255),
		background = ColorI(0, 0, 0, 127),
		orb = rgbToColorF(0, 127, 255, 64),
		postfix = ' [Helicopter Postfix]'
	},
	Leshii413 = { -- Baja75
		textcolor = rgbToColorF(0, 0, 0),
		background = ColorI(0, 169, 255, 127),
		orb = rgbToColorF(0, 169, 255, 64),
		postfix = ' [Owner Heli]'
	},
	Sauwercraud = { -- BeamMP
		textcolor = rgbToColorF(0, 0, 0),
		background = ColorI(243, 109, 36, 127),
		orb = rgbToColorF(243, 109, 36, 64),
		postfix = ' [BeamMP.cam]'
	},
	Poignee_de_porte = { -- BeamMP
		textcolor = rgbToColorF(252, 0, 168),
		background = ColorI(0, 252, 10, 127),
		orb = rgbToColorF(179, 0, 249, 64),
		postfix = ' [V>v<V]'
	},
	["Z-E-R-O"] = {
		textcolor = rgbToColorF(0, 0, 0),
		background = ColorI(0,255,255, 127),
		orb = rgbToColorF(80, 80, 80, 64),
		postfix = ' [RAH-66]'
	},
}