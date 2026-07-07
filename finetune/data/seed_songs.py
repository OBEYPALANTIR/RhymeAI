"""Seed songs for synthetic training-data generation.

All lyrics below are ORIGINAL fragments written for this pipeline — they are
NOT real song lyrics and must never be replaced with copyrighted material.

Each song is a dict:
  id:     unique string
  genre:  loose genre tag
  theme:  short theme string (fed to the suggestions prompt as Theme:)
  lyrics: 8-24 lines with [Verse]/[Chorus]/[Hook]/[Bridge] headers (or none,
          for unmarked-section coverage). Several songs repeat their chorus so
          the sampler can hit chorus-repeat (ordinal >= 2) contexts.

Also exported:
  THEMES     — extra theme strings for variety
  WORD_BANK  — common lyric words (each appears verbatim in at least one song)
               mapped to plausible synonyms; used for single-word rewrite
               rejected-word lists and for synonym-task word picks.
"""

SONGS = [
    {
        "id": "gravel_road", "genre": "country", "theme": "leaving home",
        "lyrics": """[Verse 1]
I packed the truck while the town was sleeping sound
Left my key beneath the flower pot
The gravel popped like static on the ground
And I whispered thanks for all that I forgot

[Chorus]
Goodbye to the water tower light
Goodbye to the fields of gold
I am chasing down a bigger night
With a heart too wild to hold

[Verse 2]
The county line was glowing in the haze
My mirror held the porch light burning low""",
    },
    {
        "id": "motel_heart", "genre": "country", "theme": "heartbreak",
        "lyrics": """[Verse 1]
You left your ring on the nightstand by the phone
A crooked note that said you tried
The parking lot was empty as a stone
And the neon vacancy just lied

[Chorus]
Now I'm living in a heartbreak motel
Where the walls are paper thin
Every door has got a story to tell
And they all sound like giving in

[Bridge]
Maybe someday I will laugh about the pain
But tonight it's just the rain""",
    },
    {
        "id": "midnight_highway", "genre": "rock", "theme": "night driving",
        "lyrics": """[Verse 1]
The dashboard glow is painting both my hands
The white lines flicker like a broken code
Radio preaching static to the bands
Of moths that marry every lonely road

[Chorus]
We ride the midnight highway
Chasing taillights through the dark
Every mile a runway
Every heartbeat is a spark

[Verse 2]
The city shrinks to embers in the glass
A hundred exits promise me the same

[Chorus]
We ride the midnight highway""",
    },
    {
        "id": "blueprint", "genre": "hip-hop", "theme": "ambition",
        "lyrics": """[Verse 1]
I sketched my future on a napkin at the diner
Coffee going cold while the plan was getting finer
Mama said the ceiling is a floor for a climber
So I stack every setback like a shrine to the grinder

[Hook]
They say wait your turn, I built the clock
Drew a blueprint out of every block
Every no I heard is scaffold now
Watch me raise the roof and take a bow

[Verse 2]
Elevator broken so I took the stairs to glory
Every scar a chapter in a self-made story""",
    },
    {
        "id": "corner_lights", "genre": "hip-hop", "theme": "city life",
        "lyrics": """[Verse 1]
Streetlights hum a sermon over cracked concrete
Bodega cat is dozing while the sirens repeat
Every window is a story stacked a hundred feet
And the city keeps its rhythm on a snare-drum beat

[Chorus]
Corner lights burning gold
Keep the block from growing cold
Every dreamer needs a flame
So the night remembers every name

[Bridge]
When the last train rattles home
Nobody here is ever alone""",
    },
    {
        "id": "paper_crowns", "genre": "pop", "theme": "chasing fame",
        "lyrics": """[Verse 1]
I practiced my acceptance speech at seventeen
In a bedroom with a hairbrush microphone
Taped my posters up like windows to a scene
Where nobody ever sings alone

[Chorus]
We wear our paper crowns tonight
Dancing till the streetlights fade
Even if the gold is fake, the dream is right
We were never meant to be afraid

[Verse 2]
The open mic is empty on a Tuesday night
But I sing like the balcony is full

[Chorus]
We wear our paper crowns tonight""",
    },
    {
        "id": "summer_static", "genre": "pop", "theme": "nostalgia",
        "lyrics": """[Verse 1]
Polaroids are curling on my bedroom wall
Your laughter trapped in amber in my mind
We spent July pretending fall would never call
And left our bikes and better sense behind

[Chorus]
Summer static on the radio
Every song we used to know
Time moves fast but we moved slow
Barefoot in the afterglow

[Bridge]
If I could bottle one more June
I would never open it too soon""",
    },
    {
        "id": "iron_bloom", "genre": "rock", "theme": "resilience",
        "lyrics": """[Verse 1]
They poured the doubt like concrete on my chest
Expected me to set and stay in place
But flowers split the sidewalk without rest
And I grew crooked toward the light with grace

[Chorus]
I am an iron bloom
Rusting into red
Growing through the gloom
Stronger than they said

[Verse 2]
Every storm that tried to bend me down
Left its water in my roots to drink""",
    },
    {
        "id": "harvest_letters", "genre": "folk", "theme": "nostalgia",
        "lyrics": """[Verse 1]
I found your letters in the harvest tin
Beneath the twine and baling wire
The ink has faded thin as onion skin
But the words still crackle like a fire

[Chorus]
Read me one more page tonight
Under the harvest moon so bright
Every sentence is a light
Leading wagons through the night

[Verse 2]
The barn still leans the way it always did
The swallows stitch the evening to the eaves""",
    },
    {
        "id": "river_teeth", "genre": "folk", "theme": "letting go",
        "lyrics": """[Verse 1]
The river keeps whatever we throw in
Old keys and promises and pride
It polishes our sorrow on its skin
And carries what we cannot hide

[Chorus]
Let it go down to the delta
Let the current take its share
What the water wants, the water gets
And it always leaves us lighter there

[Bridge]
I dropped your name into the shallows
Watched it shimmer out of sight""",
    },
    {
        "id": "velvet_hours", "genre": "R&B", "theme": "first love",
        "lyrics": """[Verse 1]
Two glasses sweating on the windowsill
The record spinning something soft and slow
Your hand in mine, the city standing still
The lamplight wrapped us in a velvet glow

[Chorus]
These velvet hours moving honey slow
Every minute is a place to go
Hold me like the morning is a rumor
Love me like the night will never know

[Verse 2]
Your perfume settled in my collar seam
I memorized the freckle constellation""",
    },
    {
        "id": "slow_smoke", "genre": "R&B", "theme": "heartbreak",
        "lyrics": """[Verse 1]
Your side of the closet is an open wound
Hangers swinging empty in the dark
The candle you forgot is burning through the afternoon
And every flicker is a question mark

[Chorus]
Love left like slow smoke
Curling through my door
No goodbye was ever spoke
Just a jacket on the floor

[Bridge]
I keep the window open wide
In case the wind brings you inside

[Chorus]
Love left like slow smoke""",
    },
    {
        "id": "bus_ticket_east", "genre": "country", "theme": "leaving home",
        "lyrics": """[Verse 1]
Daddy shook my hand like I was grown
Mama tucked a twenty in my coat
The depot clock was older than the town
And the diesel hummed a trembling note

[Chorus]
One bus ticket heading east
A duffel bag and a folded map
Eighteen years and a moving feast
Of everything I can't unpack

[Verse 2]
The fields rolled by like pages in a book
I read the fences, memorized the creek""",
    },
    {
        "id": "rust_and_rain", "genre": "country", "theme": "working-class pride",
        "lyrics": """[Verse 1]
The mill shut down the summer I turned ten
Dad came home with sawdust in his eyes
He fixed the fence and fixed it once again
Because a man needs something that complies

[Chorus]
We are rust and rain and second shifts
Coffee black and hand-me-down gifts
Steel-toed boots by the kitchen door
Proud of what we're working for

[Bridge]
They can shutter every line
But they can't repossess the pine""",
    },
    {
        "id": "glass_city", "genre": "pop", "theme": "city life",
        "lyrics": """[Verse 1]
A thousand windows wearing morning gold
The subway breathes beneath the avenue
I bought a coffee and a stranger's cold
And wondered if the skyline missed me too

[Chorus]
Glass city, hold me up tonight
Mirror all my broken light
Every crack a place to shine
Glass city, you are mine

[Verse 2]
The pigeons argue politics on wires
The bakery is praying in perfume

[Chorus]
Glass city, hold me up tonight""",
    },
    {
        "id": "borrowed_time", "genre": "rock", "theme": "ambition",
        "lyrics": """[Verse 1]
I clocked out of my future at the plant
Told the foreman I was done with slow
He laughed and said that dreamers always can't
I framed his doubt and hung it where I go

[Chorus]
I'm spending borrowed time like cash
Burning every bridge to light the path
If the wheels come off, at least I flew
Better broke than never true

[Verse 2]
The van is running on a prayer and fumes
Our name is spray-paint on the amp""",
    },
    {
        "id": "porchlight", "genre": "folk", "theme": "growing up",
        "lyrics": """[Verse 1]
Mama kept the porchlight burning amber
Every summer I was running late
The screen door learned the rhythm of my sneakers
And the fireflies would meet me at the gate

[Chorus]
Leave the porchlight on for me
No matter how far I roam
Half of every road I see
Is just another way back home

[Verse 2]
Now the paint is peeling off the railing
The maple we planted swallows up the sky""",
    },
    {
        "id": "neon_river", "genre": "R&B", "theme": "night driving",
        "lyrics": """[Verse 1]
Taillights bleeding crimson down the boulevard
The bass line rolling velvet through the doors
Your silhouette is soft against the stars
We float on asphalt, midnight metaphors

[Chorus]
Ride with me down the neon river
Windows down and the summer sighing
Every streetlight makes me shiver
City lullabies and low lights flying

[Verse 2]
The bridge cables strum a quiet chord
We idle where the water eats the light""",
    },
    {
        "id": "plain_storm", "genre": "folk", "theme": "a storm rolling in",
        "lyrics": """The clouds rolled in like freight across the plain
I counted seconds between light and sound
The screen door slammed a warning to the rain
And every dog for miles was homeward bound
The gutters sang a muddy hallelujah
The porch swing rocked with nobody aboard
I watched the lightning practice its own sermon
And write its signature across the ford""",
    },
    {
        "id": "plain_kitchen", "genre": "country", "theme": "missing someone",
        "lyrics": """The kitchen still remembers how she hummed
Flour ghosts are sleeping in the cracks
The clock above the stove has never chimed
Since the morning that she never came back
The kettle keeps her whistle in its throat
And I keep her recipes by heart
The window plants lean toward an empty chair
And even Sunday falls apart""",
    },
    {
        "id": "plain_shift", "genre": "rock", "theme": "night shift",
        "lyrics": """Three in the morning and the forklift hums
The warehouse lights are colder than the moon
I stack the boxes higher than my doubts
And whistle to the barcode scanner's tune
My daughter's drawing folded in my vest
A crayon sun that keeps me pointed west
The clock hands crawl but paychecks learn to run
And every graveyard shift still meets the sun""",
    },
    {
        "id": "gold_gutter", "genre": "hip-hop", "theme": "resilience",
        "lyrics": """[Verse 1]
They flooded my block and I learned how to swim
Turned a cracked foundation to a diving rim
Every eviction notice, I fold it to a plane
Watch it glide through the thunder, get golden in the rain

[Hook]
There is gold in the gutter if you look
Every stumble is a page in the book
Keep your chin up out the water, stay afloat
Turn the wreckage of the flood into a boat

[Verse 2]
Grandma prayed in the stairwell, candles on nine
Said the pressure makes a diamond out of coal in time

[Hook]
There is gold in the gutter if you look""",
    },
    {
        "id": "last_train_west", "genre": "folk", "theme": "wanderlust",
        "lyrics": """[Verse 1]
The station master yawns behind the glass
The midnight schedule flutters in the draft
I bought a window seat to watch the past
Unspool behind me like a paper raft

[Chorus]
Take the last train west, my friend
Where the maps run out of names
Every ending has a bend
And the sky forgives our aims

[Bridge]
I left a letter with no address
Signed it, wish me luck, love, restless""",
    },
    {
        "id": "sugar_smoke", "genre": "pop", "theme": "first love",
        "lyrics": """[Verse 1]
Cotton candy melting on the midway
Your hand was trembling when it found my own
The ferris wheel was spinning slow on Friday
And I forgot the way to get back home

[Chorus]
You taste like sugar, burn like smoke
Every word a spark you spoke
My paper heart went up in flames
And I wrote the ashes both our names

[Verse 2]
The carnival packed up and left the lot
But the lights keep spinning in my chest""",
    },
    {
        "id": "desert_radio", "genre": "rock", "theme": "night driving",
        "lyrics": """[Verse 1]
The saguaros salute the setting sun
The blacktop shimmers like a broken mirror
One station playing gospel, one plays none
And every empty mile is getting clearer

[Chorus]
Desert radio, sing me through the dark
Static angels humming in the spark
A hundred miles of nothing, nothing true
Just me, the moon, the dial, and you

[Verse 2]
A coyote quotes the chorus to the moon
The dashboard saints are dancing on the dash""",
    },
    {
        "id": "winter_engine", "genre": "country", "theme": "resilience",
        "lyrics": """[Verse 1]
The engine coughed like an old man in the cold
I cussed the frost and hit the wheel again
The heater blew a memory of gold
From summers when the truck and I were ten

[Chorus]
Turn over, turn over, one more time
We have made it through the worst of white
Every winter is a mountain climb
And every spring, the summit's bright

[Bridge]
The driveway drifts are chest-high deep
But promises are mine to keep""",
    },
    {
        "id": "stairwell_choir", "genre": "R&B", "theme": "city life",
        "lyrics": """[Verse 1]
The radiator sings in broken keys
Somebody's baby laughing down the hall
The stairwell choir of strangers and their dreams
Is written in the marker on the wall

[Chorus]
We harmonize between the floors
Every heartache finds a chord
Open windows, open doors
Every voice its own reward

[Verse 2]
Miss Carter waters roses on the sill
The mailman whistles something soft and old

[Chorus]
We harmonize between the floors""",
    },
]

# Extra themes for prompt variety (the sampler sometimes swaps the song's own
# theme for one of these, or sends "" to exercise the infer-from-lyrics path).
THEMES = [
    "leaving home", "heartbreak", "ambition", "night driving", "resilience",
    "city life", "nostalgia", "first love", "letting go", "wanderlust",
    "working-class pride", "growing up", "missing someone", "a storm rolling in",
    "chasing fame", "small-town summer", "starting over", "homesick on the road",
]

# Common lyric words -> plausible synonyms. Every key appears verbatim
# (whole-word, as written) in at least one song above; the self-test asserts it.
WORD_BANK = {
    "glow": ["gleam", "shine", "shimmer"],
    "cold": ["chill", "frost", "freeze"],
    "broken": ["shattered", "cracked", "battered"],
    "empty": ["hollow", "vacant", "bare"],
    "burning": ["blazing", "flaming", "glowing"],
    "trembling": ["shaking", "shivering", "quaking"],
    "crooked": ["bent", "slanted", "tilted"],
    "lonely": ["lonesome", "solitary", "forsaken"],
    "spark": ["flicker", "flash", "ember"],
    "storm": ["tempest", "squall", "gale"],
    "fade": ["dim", "vanish", "wither"],
    "shimmer": ["glimmer", "sparkle", "glisten"],
    "quiet": ["silent", "hushed", "gentle"],
    "gold": ["amber", "gilt", "honey"],
    "flicker": ["waver", "sputter", "pulse"],
    "doubt": ["worry", "dread", "fear"],
    "sorrow": ["grief", "sadness", "mourning"],
    "shiver": ["tremble", "quiver", "shudder"],
    "wild": ["untamed", "reckless", "feral"],
    "whispered": ["murmured", "muttered", "breathed"],
    "rumor": ["whisper", "gossip", "secret"],
    "wreckage": ["ruins", "debris", "rubble"],
    "restless": ["sleepless", "uneasy", "wired"],
    "flames": ["fire", "blazes", "embers"],
    "static": ["noise", "crackle", "buzz"],
}


def _self_test():
    import re

    ids = [s["id"] for s in SONGS]
    assert len(ids) == len(set(ids)), "duplicate song ids"
    assert len(SONGS) >= 25, "need at least 25 songs, have %d" % len(SONGS)

    header_re = re.compile(r"^\s*\[.+]\s*$")
    repeat_chorus = 0
    for song in SONGS:
        lines = song["lyrics"].split("\n")
        lyric_lines = [
            l for l in lines if l.strip() and not header_re.match(l)
        ]
        assert 8 <= len(lyric_lines) <= 24, (
            "%s has %d lyric lines" % (song["id"], len(lyric_lines))
        )
        headers = [l for l in lines if header_re.match(l)]
        chorus_like = [
            h for h in headers if "chorus" in h.lower() or "hook" in h.lower()
        ]
        if len(chorus_like) >= 2:
            repeat_chorus += 1
    assert repeat_chorus >= 4, "need several repeat-chorus songs"

    all_lyrics = "\n".join(s["lyrics"] for s in SONGS)
    for word in WORD_BANK:
        pattern = re.compile(r"(?<![\w'])%s(?![\w'])" % re.escape(word))
        assert pattern.search(all_lyrics), "bank word %r not found in songs" % word

    print("songs: %d (repeat-chorus: %d), themes: %d, word bank: %d — OK" % (
        len(SONGS), repeat_chorus, len(THEMES), len(WORD_BANK)
    ))


if __name__ == "__main__":
    _self_test()
