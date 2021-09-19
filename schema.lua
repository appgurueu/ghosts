return {
	type = "table",
	entries = {
		particles_per_metre = {
			type = "number",
			description = "Particles per one metre (= node size)",
			min = 1,
			max = 100,
			default = 10
		},
		spawn_chance = {
			type = "number",
			description = "Chance of a ghost spawning the first night",
			min = 0,
			max = 1,
			default = 1
		},
		chance_reduction_per_night = {
			type = "number",
			description = "Decrease in chance of ghost spawning per night",
			min = 0,
			max = 1,
			default = 0.5
		},
		forget_duration_nights = {
			type = "number",
			description = "How many nights it takes for a ghost to forget their victim",
			default = 10,
		},
		fallback_resolution = {
			type = "table",
			entries = {
				{
					type = "number",
					description = "Fallback resolution width",
					default = 64
				},
				{
					type = "number",
					description = "Fallback resolution height",
					default = 64
				}
			}
		},
		force_fallback_resolution = {
			type = "boolean",
			description = "Whether to always resize textures to the given fallback dimensions. Guarantees support for arbitrary resolution texture packs. If this is not set, texture packs with a resolution lower than the server texture resolution won't work at all; texture packs with a multiple of said resolution will work well, however. A resolution of 64x64 or lower is usually acceptable performance-wise.",
			default = false
		}
	}
}