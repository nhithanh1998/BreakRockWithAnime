--!strict
-- ChatConfig: what the NPCs say in their speech bubbles (client ChatBubble draws them).
--
--   Customers   sold out: one of SoldOutLines, then walk off; bought: now and then one of BoughtLines
--   Keepers     the heroes behind the stand's counter: say sorry (and look embarrassed) when a customer
--               finds the stand sold out; now and then thank a customer who bought something
--   Workers     the heroes chopping trees on the plot: say something every Min..Max seconds (only the
--               ones near the camera), and now and then another worker on the same plot answers
--
-- Any line may get an emoji at the end: EmojiChance of the time, one from Emojis[<mood of the list>].
-- A line that already ends in an emoji (or ":(" etc.) never gets a second one.

local ChatConfig = {}

ChatConfig.EmojiChance = 0.45
ChatConfig.Emojis = {
	Sad = { "😢", "😞", "😭", "💔", "😩", "🥺" },
	Sorry = { "🙏", "😅", "😳", "🙇", "💦", "😬" },
	Happy = { "😊", "😄", "🥰", "✨", "👍", "💰", "🎉" },
	Work = { "🪓", "💪", "🌳", "🔥", "😤", "🪵", "⚡" },
	Chill = { "😎", "😴", "🍃", "🎶", "☀️", "🤔" },
} :: { [string]: { string } }

ChatConfig.Bubble = {
	Time = 3, -- seconds a bubble stays (sold out lines use StandConfig.Customers.UpsetTime)
	MaxDistance = 90, -- studs from the camera
	TextSize = 18,
	MaxWidth = 260, -- pixels; longer lines wrap
	CustomerOffset = 3.4, -- studs above the head
	HeroOffset = 4.6, -- studs above the head (heroes have their HeroBar there)
}

ChatConfig.Customer = {
	BoughtChance = 0.2, -- of the customers who bought something
	SoldOutMood = "Sad",
	SoldOutLines = {
		"Aww, sold out...",
		"Nothing left?!",
		"I'll come back later...",
		"Empty again?",
		"Seriously? No stock?",
		"Guess I'm too late...",
		"Restock please!",
		"I walked all the way here...",
	},
	BoughtMood = "Happy",
	BoughtLines = {
		"Fresh stuff!",
		"Best stand in town!",
		"Totally worth it!",
		"My mom will love this!",
		"Yay, got some!",
		"See you tomorrow!",
	},
}

ChatConfig.Keeper = {
	SorryCooldown = 3.5, -- seconds between two "sorry"s of the same stand
	EmbarrassedTime = 2.6, -- seconds of the embarrassed pose (scratches the back of the head, looks down)
	SorryMood = "Sorry",
	SorryLines = {
		"Sorry! We're sold out!",
		"So sorry, restocking soon!",
		"Ahh, all gone... sorry!",
		"Please come back later!",
		"My bad, nothing left!",
		"Sorry~ the shelves are empty!",
		"Eh-heh... out of stock...",
	},
	ThanksChance = 0.15, -- of the sales
	ThanksMood = "Happy",
	ThanksLines = {
		"Thank you!",
		"Come again!",
		"Enjoy!",
		"Have a nice day!",
		"Thanks for buying!",
	},
}

ChatConfig.Worker = {
	Min = 14, -- seconds between two lines of one worker
	Max = 32,
	Range = 80, -- only workers this close to the camera talk
	MaxTalking = 3, -- bubbles at once (all workers)
	ReplyChance = 0.35, -- another worker on the plot answers
	ReplyDelay = 1.6,
	Lines = {
		Work = {
			"This tree is tough!",
			"Timber!",
			"One more swing!",
			"Chop chop chop!",
			"Feel the power!",
			"Nothing can stop me!",
			"Who planted this one?!",
			"My axe is on fire today!",
			"Watch and learn!",
			"Hyaaa!",
		},
		Chill = {
			"Nice weather today.",
			"Break time soon?",
			"I'm getting hungry...",
			"The boss is watching!",
			"Hey, nice swing!",
			"Is it payday yet?",
			"I could do this all day.",
			"Anyone seen my sandwich?",
		},
	} :: { [string]: { string } },
	Replies = {
		"Haha, true!",
		"Less talk, more chopping!",
		"Same here!",
		"You said that yesterday!",
		"Focus!",
		"Race you to the next tree!",
		"Mine's bigger!",
		"Keep it up!",
	},
	ReplyMood = "Chill",
}

return ChatConfig
